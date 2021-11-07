# Activate the environment for running the script
if isfile("Project.toml") && isfile("Manifest.toml")
    import Pkg
    Pkg.activate(".")
end

using Dates, Statistics, CairoMakie, DataFrames, DataDeps, DiffEqFlux, Covid19ModelVN

import Covid19ModelVN.JHUCSSEData,
    Covid19ModelVN.FacebookData,
    Covid19ModelVN.PopulationData,
    Covid19ModelVN.VnExpressData,
    Covid19ModelVN.VnCdcData

has_irdc(loc) = loc == Covid19ModelVN.LOC_CODE_VIETNAM

has_dc(loc) =
    loc == Covid19ModelVN.LOC_CODE_UNITED_STATES ||
    loc ∈ keys(Covid19ModelVN.LOC_NAMES_VN) ||
    loc ∈ keys(Covid19ModelVN.LOC_NAMES_US)

function experiment_covid19_counts_reset!(df::AbstractDataFrame, loc::AbstractString)
    first_date, last_date = if loc == Covid19ModelVN.LOC_CODE_VIETNAM
        # we considered 27th April 2021 to be the start of the outbreak in Vietnam
        # 4th August 2021 is when no recovered cases are recorded in JHU data
        Date(2021, 4, 27), Date(2021, 8, 4)
    elseif loc == Covid19ModelVN.LOC_CODE_UNITED_STATES ||
           loc ∈ keys(Covid19ModelVN.LOC_NAMES_US)
        # we considered 1st July 2021 to be the start of the outbreak in the US
        # 30th September 2021 is for getting a long enough period
        Date(2021, 7, 1), Date(2021, 9, 30)
    else
        # data for other locations don't need processing
        return df
    end

    # make the cases count starts from the first date of the considered outbreak
    bound!(df, :date, first_date - Day(1), last_date)
    datacols = names(df, Not(:date))
    starting_states = Array(df[1, datacols])
    transform!(df, datacols => ByRow((x...) -> x .- starting_states) => datacols)
    bound!(df, :date, first_date, last_date)
    return df
end

function experiment_covid19_data(loc::AbstractString, train_range::Day, forecast_range::Day)
    cols = if has_irdc(loc)
        ["infective", "recovered_total", "deaths_total", "confirmed_total"]
    elseif has_dc(loc)
        ["deaths_total", "confirmed_total"]
    else
        throw("Unsupported location code '$loc'!")
    end

    df = get_prebuilt_covid_timeseries(loc)
    experiment_covid19_counts_reset!(df, loc)
    # choose the first date to be when the number of total confirmed cases passed 500
    first_date = first(subset(df, :confirmed_total => x -> x .>= 500, view = true).date)
    split_date = first_date + train_range - Day(1)
    last_date = split_date + forecast_range
    @info [first_date; split_date; last_date]
    # smooth out weekly seasonality
    moving_average!(df, cols, 7)
    conf = TimeseriesConfig(df, :date, cols)
    # split data into 2 parts for training and testing
    train_dataset, test_dataset = train_test_split(conf, first_date, split_date, last_date)

    return train_dataset, test_dataset, first_date, last_date
end

function experiment_movement_range(loc::AbstractString, first_date::Date, last_date::Date)
    df = get_prebuilt_movement_range(loc)
    cols = [:all_day_bing_tiles_visited_relative_change, :all_day_ratio_single_tile_users]
    # smooth out weekly seasonality
    moving_average!(df, cols, 7)
    return load_timeseries(TimeseriesConfig(df, :ds, cols), first_date, last_date)
end

function experiment_social_proximity(loc::AbstractString, first_date::Date, last_date::Date)
    df, col = get_prebuilt_social_proximity(loc)
    # smooth out weekly seasonality
    moving_average!(df, col, 7)
    return load_timeseries(TimeseriesConfig(df, :date, col), first_date, last_date)
end

function experiment_SEIRD_initial_states(loc::AbstractString, data::AbstractVector{<:Real})
    population = get_prebuilt_population(loc)
    u0, vars, labels = if has_irdc(loc)
        # Infective, Recovered, Deaths, Cummulative are observable
        I0 = data[1] # infective individuals
        R0 = data[2] # recovered individuals
        D0 = data[3] # total deaths
        C0 = data[4] # total confirmed
        N0 = population - D0 # effective population
        E0 = I0 * 2 # exposed individuals
        S0 = population - C0 - E0 # susceptible individuals
        # initial state
        u0 = [S0, E0, I0, R0, D0, C0, N0]
        vars = [3, 4, 5, 6]
        labels = ["infective", "recovered", "deaths", "total confirmed"]
        # return values to outer scope
        u0, vars, labels
    elseif has_dc(loc)
        # Deaths, Cummulative are observable
        D0 = data[1] # total deaths
        C0 = data[2] # total confirmed
        I0 = div(C0 - D0, 2) # infective individuals
        R0 = C0 - I0 - D0 # recovered individuals
        N0 = population - D0 # effective population
        E0 = I0 * 2 # exposed individuals
        S0 = population - C0 - E0 # susceptible individuals
        # initial state
        u0 = [S0, E0, I0, R0, D0, C0, N0]
        vars = [5, 6]
        labels = ["deaths", "total confirmed"]
        # return values to outer scope
        u0, vars, labels
    else
        throw("Unsupported location code '$loc'!")
    end
    return u0, vars, labels
end

function experiment_loss(predictor::Predictor, dataset::TimeseriesDataset, ζ::Float64)
    weights = exp.(collect(dataset.tsteps) .* ζ)
    lossfn = (ŷ, y) -> sum(mean((ŷ .- y) .^ 2 .* weights', dims = 2))
    loss = Loss(lossfn, predictor, dataset)
    return loss
end