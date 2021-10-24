module Datasets

export TimeseriesDataset,
    load_timeseries,
    train_test_split,
    DEFAULT_VIETNAM_GADM1_POPULATION_DATASET,
    DEFAULT_VIETNAM_COVID_DATA_TIMESERIES,
    DEFAULT_VIETNAM_PROVINCES_CONFIRMED_TIMESERIES,
    DEFAULT_VIETNAM_PROVINCES_TOTAL_CONFIRMED_TIMESERIES,
    DEFAULT_VIETNAM_AVERAGE_MOVEMENT_RANGE,
    DEFAULT_VIETNAM_INTRA_CONNECTEDNESS_INDEX,
    DEFAULT_VIETNAM_PROVINCE_CONFIRMED_AND_DEATHS_TIMESERIES,
    DEFAULT_VIETNAM_PROVINCE_AVERAGE_MOVEMENT_RANGE,
    DEFAULT_VIETNAM_SOCIAL_PROXIMITY_TO_CASES_INDEX

using Dates, DataFrames, Statistics
import Covid19ModelVN.FacebookData,
    Covid19ModelVN.VnExpressData, Covid19ModelVN.PopulationData, Covid19ModelVN.VnCdcData

DEFAULT_VIETNAM_SOCIAL_PROXIMITY_TO_CASES_INDEX(datasets_dir; recreate = false) =
    FacebookData.save_social_proximity_to_cases_index(
        joinpath(datasets_dir, "VNM-gadm1-population.csv"),
        joinpath(
            datasets_dir,
            "20210427-20211013-vietnam-provinces-confirmed-timeseries.csv",
        ),
        joinpath(datasets_dir, "VNM-facebook-intra-connectedness-index.csv"),
        datasets_dir,
        "VNM-social-proximity-to-cases",
        recreate = recreate,
    )

DEFAULT_VIETNAM_PROVINCE_CONFIRMED_AND_DEATHS_TIMESERIES(datasets_dir, name) =
    VnCdcData.parse_json_cases_and_deaths(joinpath(datasets_dir, "vncdc", "$name.json"))

DEFAULT_VIETNAM_PROVINCE_AVERAGE_MOVEMENT_RANGE(
    datasets_dir,
    province_id;
    recreate = false,
) = FacebookData.save_country_average_movement_range(
    joinpath(
        datasets_dir,
        "facebook",
        "movement-range-data-2021-10-09",
        "movement-range-2021-10-09.txt",
    ),
    datasets_dir,
    "facebook-average-movement-range",
    "VNM",
    province_id,
    recreate = recreate,
)


DEFAULT_VIETNAM_GADM1_POPULATION_DATASET(datasets_dir; recreate = false) =
    PopulationData.save_vietnam_gadm1_population(
        joinpath(datasets_dir, "gadm", "VNM_adm.gpkg"),
        joinpath(datasets_dir, "gso", "VNM-2020-population-all-regions.csv"),
        datasets_dir,
        "VNM-gadm1-population",
        recreate = recreate,
    )

DEFAULT_VIETNAM_COVID_DATA_TIMESERIES(datasets_dir; recreate = false) =
    VnExpressData.save_cases_timeseries(
        datasets_dir,
        "vietnam-covid-data-timeseries",
        Date(2021, 4, 27),
        Date(2021, 10, 13),
        recreate = recreate,
    )

DEFAULT_VIETNAM_PROVINCES_CONFIRMED_TIMESERIES(datasets_dir; recreate = false) =
    VnExpressData.save_provinces_confirmed_cases_timeseries(
        datasets_dir,
        "vietnam-provinces-confirmed-timeseries",
        Date(2021, 4, 27),
        Date(2021, 10, 13),
        recreate = recreate,
    )

DEFAULT_VIETNAM_PROVINCES_TOTAL_CONFIRMED_TIMESERIES(datasets_dir; recreate = false) =
    VnExpressData.save_provinces_total_confirmed_cases_timeseries(
        datasets_dir,
        "vietnam-provinces-total-confirmed-timeseries",
        Date(2021, 4, 27),
        Date(2021, 10, 13),
        recreate = recreate,
    )

DEFAULT_VIETNAM_AVERAGE_MOVEMENT_RANGE(datasets_dir; recreate = false) =
    FacebookData.save_country_average_movement_range(
        joinpath(
            datasets_dir,
            "facebook",
            "movement-range-data-2021-10-09",
            "movement-range-2021-10-09.txt",
        ),
        datasets_dir,
        "facebook-average-movement-range",
        "VNM",
        recreate = recreate,
    )

DEFAULT_VIETNAM_INTRA_CONNECTEDNESS_INDEX(datasets_dir; recreate = false) =
    FacebookData.save_intra_country_gadm1_nuts2_connectedness_index(
        joinpath(
            datasets_dir,
            "facebook",
            "social-connectedness-index",
            "gadm1_nuts2_gadm1_nuts2_aug2020.tsv",
        ),
        datasets_dir,
        "facebook-intra-connectedness-index",
        "VNM",
        recreate = recreate,
    )

view_dates_range(df::DataFrame, col, start_date::Date, end_date::Date) =
    view(df, (df[!, col] .>= start_date) .& (df[!, col] .<= end_date), All())

moving_average(xs, n::Int) =
    [mean(@view xs[(i >= n ? i - n + 1 : 1):i]) for i = 1:length(xs)]

moving_average!(df::DataFrame, cols, n::Int) =
    transform!(df, names(df, Cols(cols)) .=> x -> moving_average(x, n), renamecols = false)

"""
This contains the minimum required information for a timeseriese dataset that is used by UDEs

# Fields

* `data::AbstractArray{<:Real}`: an array that holds the timeseries data
* `tspan::Tuple{<:Real,<:Real}`: the first and last time coordinates of the timeseries data
* `tsteps::Union{Real,AbstractVector{<:Real},StepRange,StepRangeLen}`: collocations points
"""
struct TimeseriesDataset
    data::AbstractArray{<:Real}
    tspan::Tuple{<:Real,<:Real}
    tsteps::Union{Real,AbstractVector{<:Real},StepRange,StepRangeLen}
end

function train_test_split(
    df::DataFrame,
    data_cols,
    date_col,
    first_date::Date,
    split_date::Date,
    last_date::Date,
)
    df_train = view_dates_range(df, date_col, first_date, split_date)
    df_test = view_dates_range(df, date_col, split_date + Day(1), last_date)

    train_tspan = Float64.((0, Dates.value(split_date - first_date)))
    test_tspan = Float64.((0, Dates.value(last_date - first_date)))

    train_tsteps = train_tspan[1]:1:train_tspan[2]
    test_tsteps = (train_tspan[2]+1):1:test_tspan[2]

    train_data = Float64.(Array(df_train[!, data_cols])')
    test_data = Float64.(Array(df_test[!, data_cols])')

    train_dataset = TimeseriesDataset(train_data, train_tspan, train_tsteps)
    test_dataset = TimeseriesDataset(test_data, test_tspan, test_tsteps)

    return train_dataset, test_dataset
end

function load_timeseries(
    df::DataFrame,
    data_cols,
    date_col,
    first_date::Date,
    last_date::Date,
)
    df = view_dates_range(df, date_col, first_date, last_date)
    return Array(df[!, Cols(data_cols)])
end

end
