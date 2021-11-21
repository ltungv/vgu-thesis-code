using Dates, LinearAlgebra, Statistics, Serialization
using OrdinaryDiffEq, DiffEqFlux
using CairoMakie
using DataFrames
using Covid19ModelVN
using JSON

import Covid19ModelVN.JHUCSSEData,
    Covid19ModelVN.FacebookData,
    Covid19ModelVN.PopulationData,
    Covid19ModelVN.VnExpressData,
    Covid19ModelVN.VnCdcData

has_irdc(loc) = loc == Covid19ModelVN.LOC_CODE_VIETNAM

has_dc(loc) =
    has_irdc(loc) ||
    loc == Covid19ModelVN.LOC_CODE_UNITED_STATES ||
    loc ∈ keys(Covid19ModelVN.LOC_NAMES_VN) ||
    loc ∈ keys(Covid19ModelVN.LOC_NAMES_US)

function experiment_covid19_data(
    loc::AbstractString,
    train_range::Day,
    forecast_range::Day,
    ma7::Bool,
)
    df = get_prebuilt_covid_timeseries(loc)
    df[!, Not(:date)] .= Float64.(df[!, Not(:date)])
    # derive newly confirmed from total confirmed
    df[!, :confirmed] .= df[!, :confirmed_total]
    df[2:end, :confirmed] .= diff(df[!, :confirmed_total])

    if loc == Covid19ModelVN.LOC_CODE_VIETNAM
        # we considered 27th April 2021 to be the start of the outbreak in Vietnam
        first_date = Date(2021, 4, 27)
        last_date = typemax(Date)
        reset_date = first_date - Day(1)
        # make the cases count starts from the first date of the considered outbreak
        bound!(df, :date, reset_date, last_date)
        df[!, Not(:date)] .= df[!, Not(:date)] .- df[1, Not(:date)]
        bound!(df, :date, first_date, last_date)
    elseif loc == Covid19ModelVN.LOC_CODE_UNITED_STATES ||
           loc ∈ keys(Covid19ModelVN.LOC_NAMES_US)
        # we considered 1st July 2021 to be the start of the outbreak in the US
        bound!(df, :date, Date(2021, 7, 1), typemax(Date))
    end

    # select data starting from when total deaths >= 5 and total confirmed >= 500
    subset!(df, :deaths_total => x -> x .>= 5, :confirmed_total => x -> x .>= 500)
    first_date = first(df.date)
    split_date = first_date + train_range - Day(1)
    last_date = split_date + forecast_range

    @info "Getting Covid-19 data for '$loc'\n" *
          "+ First train date $first_date\n" *
          "+ Last train date $split_date\n" *
          "+ Last evaluated date $last_date"

    # observable compartments
    cols = if has_irdc(loc) || has_dc(loc)
        ["confirmed", "deaths_total"]
    else
        throw("Unsupported location code '$loc'!")
    end

    # smooth out weekly seasonality
    if ma7
        moving_average!(df, cols, 7)
    end

    conf = TimeseriesConfig(df, "date", cols)
    train_dataset, test_dataset = train_test_split(conf, first_date, split_date, last_date)
    return train_dataset, test_dataset, first_date, last_date
end

function experiment_movement_range(
    loc::AbstractString,
    first_date::Date,
    last_date::Date,
    ma7::Bool,
)
    df = get_prebuilt_movement_range(loc)
    cols = ["all_day_bing_tiles_visited_relative_change", "all_day_ratio_single_tile_users"]
    df[!, cols] .= Float64.(df[!, cols])
    # smooth out weekly seasonality
    if ma7
        moving_average!(df, cols, 7)
    end
    return load_timeseries(TimeseriesConfig(df, "ds", cols), first_date, last_date)
end

function experiment_social_proximity(
    loc::AbstractString,
    first_date::Date,
    last_date::Date,
    ma7::Bool,
)
    df, col = get_prebuilt_social_proximity(loc)
    df[!, col] .= Float64.(df[!, col])
    # smooth out weekly seasonality
    if ma7
        moving_average!(df, col, 7)
    end
    return load_timeseries(TimeseriesConfig(df, "date", [col]), first_date, last_date)
end

function experiment_SEIRD_initial_states(loc::AbstractString, data::AbstractVector{<:Real})
    population = get_prebuilt_population(loc)
    u0, vars, labels = if has_irdc(loc) || has_dc(loc)
        # Deaths, Cummulative are observable
        I0 = data[1] # infective individuals
        D0 = data[2] # total deaths
        R0 = 500 # recovered individuals
        N0 = population - D0 # effective population
        E0 = I0 * 2 # exposed individuals
        S0 = population - I0 - D0 - R0 - E0 # susceptible individuals
        # initial state
        u0 = Float64[S0, E0, I0, R0, D0, N0]
        vars = [3, 5]
        labels = ["new confirmed", "deaths"]
        # return values to outer scope
        u0, vars, labels
    else
        throw("Unsupported location code '$loc'!")
    end
    return u0, vars, labels
end

normed_ld(a, b) = abs(norm(a) - norm(b)) / (norm(a) + norm(b))
cosine_similarity(a, b) = dot(a, b) / (norm(a) * norm(b))
cosine_distance(a, b) = (1 - cosine_similarity(a, b)) / 2

"""
[1] R. Vortmeyer-Kley, P. Nieters, and G. Pipa, “A trajectory-based loss function to learn missing terms in bifurcating dynamical systems,” Sci Rep, vol. 11, no. 1, p. 20394, Oct. 2021, doi: 10.1038/s41598-021-99609-x.
"""
function experiment_loss(w::Tuple{R,R}) where {R<:Real}
    lossfn = function (ŷ::AbstractArray{R}, y) where {R<:Real}
        s = zero(R)
        sz = size(ŷ)
        @inbounds for j = 1:sz[2]
            @views s += w[1] * normed_ld(y[:, j], ŷ[:, j])
            @views s += w[2] * cosine_distance(y[:, j], ŷ[:, j])
        end
        return s
    end
    return lossfn
end

function experiment_loss(
    min::AbstractVector{R},
    max::AbstractVector{R},
) where {R<:Real}
    scale = max .- min
    lossfn = function (ŷ::AbstractArray{R}, y) where {R<:Real}
        s = zero(R)
        sz = size(y)
        @inbounds for j ∈ 1:sz[2], i ∈ 1:sz[1]
            s += ((ŷ[i, j] - y[i, j]) / scale[i])^2
        end
        return s
    end
    return lossfn
end

SEIRDBaselineHyperparams = @NamedTuple begin
    γ0::Float64
    λ0::Float64
    α0::Float64
    γ_bounds::Tuple{Float64,Float64}
    λ_bounds::Tuple{Float64,Float64}
    α_bounds::Tuple{Float64,Float64}
    train_range::Day
    forecast_range::Day
    ma7::Bool
end

function setup_baseline(loc::AbstractString, hyperparams::SEIRDBaselineHyperparams)
    # get data for model
    train_dataset, test_dataset = experiment_covid19_data(
        loc,
        hyperparams.train_range,
        hyperparams.forecast_range,
        hyperparams.ma7,
    )
    @assert size(train_dataset.data, 2) == Dates.value(hyperparams.train_range)
    @assert size(test_dataset.data, 2) == Dates.value(hyperparams.forecast_range)

    # initialize the model
    model = SEIRDBaseline(hyperparams.γ_bounds, hyperparams.λ_bounds, hyperparams.α_bounds)
    # get the initial states and available observations depending on the model type
    # and the considered location
    u0, vars, labels = experiment_SEIRD_initial_states(loc, train_dataset.data[:, 1])
    p0 = initparams(model, hyperparams.γ0, hyperparams.λ0, hyperparams.α0)
    train_data_min = vec(minimum(train_dataset.data, dims = 2))
    train_data_max = vec(maximum(train_dataset.data, dims = 2))
    lossfn = experiment_loss(train_data_min, train_data_max)
    return model, u0, p0, lossfn, train_dataset, test_dataset, vars, labels
end

SEIRDFbMobility1Hyperparams = @NamedTuple begin
    γ0::Float64
    λ0::Float64
    α0::Float64
    γ_bounds::Tuple{Float64,Float64}
    λ_bounds::Tuple{Float64,Float64}
    α_bounds::Tuple{Float64,Float64}
    train_range::Day
    forecast_range::Day
    ma7::Bool
end

function setup_fbmobility1(loc::AbstractString, hyperparams::SEIRDFbMobility1Hyperparams)
    # get data for model
    train_dataset, test_dataset, first_date, last_date = experiment_covid19_data(
        loc,
        hyperparams.train_range,
        hyperparams.forecast_range,
        hyperparams.ma7,
    )
    @assert size(train_dataset.data, 2) == Dates.value(hyperparams.train_range)
    @assert size(test_dataset.data, 2) == Dates.value(hyperparams.forecast_range)

    movement_range_data =
        experiment_movement_range(loc, first_date, last_date, hyperparams.ma7)
    @assert size(movement_range_data, 2) ==
            Dates.value(hyperparams.train_range) + Dates.value(hyperparams.forecast_range)

    # initialize the model
    model = SEIRDFbMobility1(
        hyperparams.γ_bounds,
        hyperparams.λ_bounds,
        hyperparams.α_bounds,
        movement_range_data,
    )
    # get the initial states and available observations depending on the model type
    # and the considered location
    u0, vars, labels = experiment_SEIRD_initial_states(loc, train_dataset.data[:, 1])
    p0 = initparams(model, hyperparams.γ0, hyperparams.λ0, hyperparams.α0)
    train_data_min = vec(minimum(train_dataset.data, dims = 2))
    train_data_max = vec(maximum(train_dataset.data, dims = 2))
    lossfn = experiment_loss(train_data_min, train_data_max)
    return model, u0, p0, lossfn, train_dataset, test_dataset, vars, labels
end

SEIRDFbMobility2Hyperparams = @NamedTuple begin
    γ0::Float64
    λ0::Float64
    α0::Float64
    γ_bounds::Tuple{Float64,Float64}
    λ_bounds::Tuple{Float64,Float64}
    α_bounds::Tuple{Float64,Float64}
    train_range::Day
    forecast_range::Day
    social_proximity_lag::Day
    ma7::Bool
end

function setup_fbmobility2(loc::AbstractString, hyperparams::SEIRDFbMobility2Hyperparams)
    # get data for model
    train_dataset, test_dataset, first_date, last_date = experiment_covid19_data(
        loc,
        hyperparams.train_range,
        hyperparams.forecast_range,
        hyperparams.ma7,
    )
    @assert size(train_dataset.data, 2) == Dates.value(hyperparams.train_range)
    @assert size(test_dataset.data, 2) == Dates.value(hyperparams.forecast_range)

    movement_range_data =
        experiment_movement_range(loc, first_date, last_date, hyperparams.ma7)
    @assert size(movement_range_data, 2) ==
            Dates.value(hyperparams.train_range) + Dates.value(hyperparams.forecast_range)

    social_proximity_data = experiment_social_proximity(
        loc,
        first_date - hyperparams.social_proximity_lag,
        last_date - hyperparams.social_proximity_lag,
        hyperparams.ma7,
    )
    @assert size(social_proximity_data, 2) ==
            Dates.value(hyperparams.train_range) + Dates.value(hyperparams.forecast_range)

    # build the model
    model = SEIRDFbMobility2(
        hyperparams.γ_bounds,
        hyperparams.λ_bounds,
        hyperparams.α_bounds,
        movement_range_data,
        social_proximity_data,
    )
    # get the initial states and available observations depending on the model type
    # and the considered location
    u0, vars, labels = experiment_SEIRD_initial_states(loc, train_dataset.data[:, 1])
    p0 = initparams(model, hyperparams.γ0, hyperparams.λ0, hyperparams.α0)
    train_data_min = vec(minimum(train_dataset.data, dims = 2))
    train_data_max = vec(maximum(train_dataset.data, dims = 2))
    lossfn = experiment_loss(train_data_min, train_data_max)
    return model, u0, p0, lossfn, train_dataset, test_dataset, vars, labels
end

SEIRDFbMobility3Hyperparams = @NamedTuple begin
    γ0::Float64
    λ0::Float64
    α0::Float64
    β_bounds::Tuple{Float64,Float64}
    γ_bounds::Tuple{Float64,Float64}
    λ_bounds::Tuple{Float64,Float64}
    α_bounds::Tuple{Float64,Float64}
    train_range::Day
    forecast_range::Day
    social_proximity_lag::Day
    ma7::Bool
end

function setup_fbmobility3(loc::AbstractString, hyperparams::SEIRDFbMobility3Hyperparams)
    # get data for model
    train_dataset, test_dataset, first_date, last_date = experiment_covid19_data(
        loc,
        hyperparams.train_range,
        hyperparams.forecast_range,
        hyperparams.ma7,
    )
    @assert size(train_dataset.data, 2) == Dates.value(hyperparams.train_range)
    @assert size(test_dataset.data, 2) == Dates.value(hyperparams.forecast_range)

    movement_range_data =
        experiment_movement_range(loc, first_date, last_date, hyperparams.ma7)
    @assert size(movement_range_data, 2) ==
            Dates.value(hyperparams.train_range) + Dates.value(hyperparams.forecast_range)

    social_proximity_data = experiment_social_proximity(
        loc,
        first_date - hyperparams.social_proximity_lag,
        last_date - hyperparams.social_proximity_lag,
        hyperparams.ma7,
    )
    @assert size(social_proximity_data, 2) ==
            Dates.value(hyperparams.train_range) + Dates.value(hyperparams.forecast_range)

    # build the model
    model = SEIRDFbMobility3(
        hyperparams.β_bounds,
        hyperparams.γ_bounds,
        hyperparams.λ_bounds,
        hyperparams.α_bounds,
        movement_range_data,
        social_proximity_data,
    )
    # get the initial states and available observations depending on the model type
    # and the considered location
    u0, vars, labels = experiment_SEIRD_initial_states(loc, train_dataset.data[:, 1])
    p0 = initparams(model, hyperparams.γ0, hyperparams.λ0, hyperparams.α0)
    train_data_min = vec(minimum(train_dataset.data, dims = 2))
    train_data_max = vec(maximum(train_dataset.data, dims = 2))
    lossfn = experiment_loss(train_data_min, train_data_max)
    return model, u0, p0, lossfn, train_dataset, test_dataset, vars, labels
end

SEIRDFbMobility4Hyperparams = @NamedTuple begin
    γ0::Float64
    λ0::Float64
    β_bounds::Tuple{Float64,Float64}
    γ_bounds::Tuple{Float64,Float64}
    λ_bounds::Tuple{Float64,Float64}
    α_bounds::Tuple{Float64,Float64}
    train_range::Day
    forecast_range::Day
    social_proximity_lag::Day
    ma7::Bool
end

function setup_fbmobility4(loc::AbstractString, hyperparams::SEIRDFbMobility4Hyperparams)
    # get data for model
    train_dataset, test_dataset, first_date, last_date = experiment_covid19_data(
        loc,
        hyperparams.train_range,
        hyperparams.forecast_range,
        hyperparams.ma7,
    )
    @assert size(train_dataset.data, 2) == Dates.value(hyperparams.train_range)
    @assert size(test_dataset.data, 2) == Dates.value(hyperparams.forecast_range)

    movement_range_data =
        experiment_movement_range(loc, first_date, last_date, hyperparams.ma7)
    @assert size(movement_range_data, 2) ==
            Dates.value(hyperparams.train_range) + Dates.value(hyperparams.forecast_range)

    social_proximity_data = experiment_social_proximity(
        loc,
        first_date - hyperparams.social_proximity_lag,
        last_date - hyperparams.social_proximity_lag,
        hyperparams.ma7,
    )
    @assert size(social_proximity_data, 2) ==
            Dates.value(hyperparams.train_range) + Dates.value(hyperparams.forecast_range)

    # build the model
    model = SEIRDFbMobility4(
        hyperparams.β_bounds,
        hyperparams.γ_bounds,
        hyperparams.λ_bounds,
        hyperparams.α_bounds,
        movement_range_data,
        social_proximity_data,
    )
    # get the initial states and available observations depending on the model type
    # and the considered location
    u0, vars, labels = experiment_SEIRD_initial_states(loc, train_dataset.data[:, 1])
    p0 = initparams(model, hyperparams.γ0, hyperparams.λ0)
    train_data_min = vec(minimum(train_dataset.data, dims = 2))
    train_data_max = vec(maximum(train_dataset.data, dims = 2))
    lossfn = experiment_loss(train_data_min, train_data_max)
    return model, u0, p0, lossfn, train_dataset, test_dataset, vars, labels
end

function experiment_train(
    uuid::AbstractString,
    setup::Function,
    configs::AbstractVector{TrainConfig},
    batchsize::Integer,
    snapshots_dir::AbstractString;
    kwargs...
)
    # get model and data
    model, u0, p0, lossfn, train_dataset, test_dataset, vars, _ = setup()
    # create a prediction model and loss function
    prob = ODEProblem(model, u0, train_dataset.tspan)
    predictor = Predictor(prob, vars)
    eval_loss = Loss(lossfn, predictor, train_dataset)
    test_loss = Loss(rmse, predictor, test_dataset)
    train_loss = if batchsize == 0
        eval_loss
    else
        Loss(lossfn, predictor, train_dataset, batchsize)
    end

    # check if AD works
    dLdθ = Zygote.gradient(train_loss, p0)
    @assert !isnothing(dLdθ[1]) # gradient is computable
    @assert any(dLdθ[1] .!= 0.0) # not all gradients are 0

    minimizers, eval_losses, test_losses = train_model(
        uuid,
        train_loss,
        eval_loss,
        test_loss,
        p0,
        configs,
        snapshots_dir;
        kwargs...
    )
    minimizer = last(minimizers)
    all_eval_losses = collect(Iterators.flatten(eval_losses))
    all_test_losses = collect(Iterators.flatten(test_losses))
    return minimizer, all_eval_losses, all_test_losses
end

function experiment_eval(
    uuid::AbstractString,
    setup::Function,
    forecast_horizons::AbstractVector{<:Integer},
    snapshots_dir::AbstractString,
)
    # get model and data
    model, u0, _, _, train_dataset, test_dataset, vars, labels = setup()
    # create a prediction model
    prob = ODEProblem(model, u0, train_dataset.tspan)
    predictor = Predictor(prob, vars)

    eval_config = EvalConfig([mae, mape, rmse], forecast_horizons, labels)
    for fpath ∈ lookup_saved_params(snapshots_dir)
        dataname, datatype, _ = rsplit(basename(fpath), ".", limit = 3)
        if !startswith(dataname, uuid)
            continue
        end

        if datatype == "losses"
            train_losses, test_losses = Serialization.deserialize(fpath)
            fig = plot_losses(train_losses, test_losses)
            save(joinpath(snapshots_dir, "$dataname.losses.png"), fig)

        elseif datatype == "params"
            minimizer = Serialization.deserialize(fpath)
            fig_forecasts, df_errors = evaluate_model(
                eval_config,
                predictor,
                minimizer,
                train_dataset,
                test_dataset,
            )
            save(joinpath(snapshots_dir, "$dataname.forecasts.png"), fig_forecasts)
            save_dataframe(df_errors, joinpath(snapshots_dir, "$dataname.errors.csv"))

            ℜe1 = ℜe(model, u0, minimizer, train_dataset.tspan, train_dataset.tsteps)
            ℜe2 = ℜe(model, u0, minimizer, test_dataset.tspan, test_dataset.tsteps)
            fig_ℜe = plot_ℜe([ℜe1; ℜe2], train_dataset.tspan[2])
            save(joinpath(snapshots_dir, "$uuid.R_effective.png"), fig_ℜe)
        end
    end

    return nothing
end

JSON.lower(x::AbstractVector{TrainConfig}) = x

JSON.lower(x::TrainConfig{ADAM}) =
    (name = x.name, maxiters = x.maxiters, eta = x.optimizer.eta, beta = x.optimizer.beta)

JSON.lower(x::TrainConfig{BFGS{IL,L,H,T,TM}}) where {IL,L,H,T,TM} = (
    name = x.name,
    maxiters = x.maxiters,
    alphaguess = IL.name.wrapper,
    linesearch = L.name.wrapper,
    initial_invH = x.optimizer.initial_invH,
    initial_stepnorm = x.optimizer.initial_stepnorm,
    manifold = TM.name.wrapper,
)

const LK_EVALUATION = ReentrantLock()

function experiment_run(
    model_name::AbstractString,
    model_setup::Function,
    locations::AbstractVector{<:AbstractString},
    hyperparams::NamedTuple,
    train_configs::AbstractVector{<:TrainConfig},
    batchsize::Integer;
    multithreading::Bool,
    forecast_horizons::AbstractVector{<:Integer},
    savedir::AbstractString,
    kwargs...
)
    minimizers = Vector{Float64}[]
    final_losses = Float64[]
    lk = ReentrantLock()

    run = function (loc)
        timestamp = Dates.format(now(), "yyyymmddHHMMSS")
        uuid = "$timestamp.$model_name.$loc"
        setup = () -> model_setup(loc, hyperparams)
        snapshots_dir = joinpath(savedir, loc)
        if !isdir(snapshots_dir)
            mkpath(snapshots_dir)
        end

        @info "Running $uuid"
        write(
            joinpath(snapshots_dir, "$uuid.hyperparams.json"),
            json((; hyperparams..., train_configs), 4),
        )
        minimizer, eval_losses, _ = experiment_train(
            uuid,
            setup,
            train_configs,
            batchsize,
            snapshots_dir;
            kwargs...
        )

        # access shared arrays
        lock(lk)
        try
            push!(minimizers, minimizer)
            push!(final_losses, last(eval_losses))
        finally
            unlock(lk)
        end

        # program crashes when multiple threads trying to plot at the same time
        lock(LK_EVALUATION)
        try
            experiment_eval(uuid, setup, forecast_horizons, snapshots_dir)
        finally
            unlock(LK_EVALUATION)
        end

        @info "Finished running $uuid"
        return nothing
    end

    if multithreading
        Threads.@threads for loc ∈ locations
            run(loc)
        end
    else
        for loc ∈ locations
            run(loc)
        end
    end

    return minimizers, final_losses
end
