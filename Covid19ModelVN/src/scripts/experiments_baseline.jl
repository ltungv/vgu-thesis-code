include("experiments.jl")

using OrdinaryDiffEq, DiffEqFlux, CairoMakie

SEIRDBaselineHyperparams = @NamedTuple begin
    ζ::Float64
    γ0::Float64
    λ0::Float64
    α0::Float64
    γ_bounds::Tuple{Float64,Float64}
    λ_bounds::Tuple{Float64,Float64}
    α_bounds::Tuple{Float64,Float64}
    train_range::Day
    forecast_range::Day
end

function setup_baseline(loc::AbstractString, hyperparams::SEIRDBaselineHyperparams)
    # get data for model
    train_dataset, test_dataset =
        experiment_covid19_data(loc, hyperparams.train_range, hyperparams.forecast_range)
    @assert size(train_dataset.data, 2) == Dates.value(hyperparams.train_range)
    @assert size(test_dataset.data, 2) == Dates.value(hyperparams.forecast_range)

    # initialize the model
    model = SEIRDBaseline(hyperparams.γ_bounds, hyperparams.λ_bounds, hyperparams.α_bounds)
    lossfn = experiment_loss(train_dataset.tsteps, hyperparams.ζ)
    p0 = initparams(model, hyperparams.γ0, hyperparams.λ0, hyperparams.α0)
    return model, lossfn, p0, train_dataset, test_dataset
end

let
    savedir = "snapshots/default"
    hyperparams = (
        ζ = 0.01,
        γ0 = 1 / 3,
        λ0 = 1 / 14,
        α0 = 0.025,
        γ_bounds = (1 / 5, 1 / 2),
        λ_bounds = (1 / 21, 1 / 7),
        α_bounds = (0.0, 0.06),
        train_range = Day(32),
        forecast_range = Day(28),
    )
    configs = TrainConfig[
        TrainConfig("500ADAM", ADAM(), 500),
        TrainConfig("500LBFGS", LBFGS(), 500),
    ]

    for loc ∈ [
        Covid19ModelVN.LOC_CODE_VIETNAM
        Covid19ModelVN.LOC_CODE_UNITED_STATES
        collect(keys(Covid19ModelVN.LOC_NAMES_VN))
        collect(keys(Covid19ModelVN.LOC_NAMES_US))
    ]
        timestamp = Dates.format(now(), "yyyymmddHHMMSS")
        plt1, plt2, df_errors = experiment_run(
            "$timestamp.baseline.$loc",
            loc,
            configs,
            () -> setup_baseline(loc, hyperparams),
            joinpath(savedir, loc),
        )
        display(plt1)
        display(plt2)
        display(df_errors)
    end
end
