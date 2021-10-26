module FacebookData

using DataDeps, Dates, DataFrames, DelimitedFiles, Statistics, Covid19ModelVN.Helpers

function __init__()
    register(
        DataDep(
            "facebook",
            """
            Dataset: Facebook Data for Good
            Website:
            + https://dataforgood.facebook.com/dfg/tools/movement-range-maps
            + https://dataforgood.facebook.com/dfg/tools/social-connectedness-index
            """,
            [
                "https://github.com/letung3105/vgu-thesis-datasets/raw/master/facebook/movement-range-data-2021-10-09.zip"
                "https://github.com/letung3105/vgu-thesis-datasets/raw/master/facebook/gadm1_nuts2-gadm1_nuts2-fb-social-connectedness-index-october-2021.zip"
            ],
            post_fetch_method = unpack,
        ),
    )
    return nothing
end

# https://arxiv.org/pdf/2109.12094.pdf
function calculate_social_proximity_to_cases(
    df_population,
    df_covid_timeseries_confirmed,
    df_social_connectedness,
)
    # get the population row with the given location id
    getloc(id) = subset(df_population, :ID_1 => x -> x .== parse(Int, id), view = true)

    df_spc = DataFrame()
    df_spc.date = df_covid_timeseries_confirmed.date

    # go through each dataframe that is grouped by the first location
    for (key, df_group) ∈ pairs(groupby(df_social_connectedness, :user_loc))
        # check if population data for the first location is available, skip if not
        first_loc = getloc(key.user_loc[4:end])
        first_loc = isempty(first_loc) ? continue : first(first_loc)

        sum_sci = sum(df_group.scaled_sci)
        df_spc[!, first_loc.NAME_1] .= 0
        # go through each location that is connected with the first location
        for row ∈ eachrow(df_group)
            # check if population data for the second location is available, skip if not
            second_loc = getloc(row.fr_loc[4:end])
            second_loc = isempty(second_loc) ? continue : first(second_loc)
            # only calculate SPC for location that has confirmed cases
            if second_loc.NAME_1 ∈ names(df_covid_timeseries_confirmed)
                df_spc[!, first_loc.NAME_1] .+=
                    (
                        df_covid_timeseries_confirmed[!, second_loc.NAME_1] ./
                        second_loc.AVGPOPULATION .* 10000
                    ) .* row.scaled_sci ./ sum_sci
            end
        end
    end

    return df_spc
end

function read_movement_range(fpath)
    data, header = readdlm(fpath, '\t', header = true)
    df = identity.(DataFrame(data, vec(header)))
    df[!, :ds] .= Date.(df[!, :ds])
    return df
end

function region_average_movement_range(
    df_movement_range,
    country_code,
    subdivision_id = nothing,
)
    df_movement_range_region =
        subset(df_movement_range, :country => x -> x .== country_code, view = true)
    if !isnothing(subdivision_id)
        df_movement_range_region = subset(
            df_movement_range_region,
            :polygon_id => x -> startswith.(x, "$country_code.$subdivision_id"),
            view = true,
        )
    end

    df_movement_range_region_avg = combine(
        DataFrames.groupby(df_movement_range_region, :ds),
        [:all_day_bing_tiles_visited_relative_change, :all_day_ratio_single_tile_users] .=> mean,
        renamecols = false,
    )
    return df_movement_range_region_avg
end

function save_region_average_movement_range(
    fpath_outputs,
    country_codes,
    subdivision_ids;
    fpath_movement_range = datadep"facebook/movement-range-2021-10-09.txt",
    recreate = false,
)
    if all(isfile, fpath_outputs) && !recreate
        return nothing
    end

    df_movement_range = FacebookData.read_movement_range(fpath_movement_range)

    for (fpath, country_code, subdivision_id) ∈
        zip(fpath_outputs, country_codes, subdivision_ids)
        if isfile(fpath) && !recreate
            return fpath
        end

        df_region_movement_range = FacebookData.region_average_movement_range(
            df_movement_range,
            country_code,
            subdivision_id,
        )
        save_dataframe(df_region_movement_range, fpath)
    end

    return nothing
end

function read_social_connectedness(fpath)
    data, header = readdlm(fpath, '\t', header = true)
    df = identity.(DataFrame(data, vec(header)))
    return df
end

inter_province_social_connectedness(df_social_connectedness, country_code) = subset(
    df_social_connectedness,
    [:user_loc, :fr_loc] =>
        ((x, y) -> startswith.(x, country_code) .& startswith.(y, country_code)),
    view = true,
)

function save_inter_province_social_connectedness(
    fpath_outputs,
    country_codes;
    fpath_social_connectedness = datadep"facebook/gadm1_nuts2_gadm1_nuts2.tsv",
    recreate = false,
)
    if all(isfile, fpath_outputs) && !recreate
        return nothing
    end

    df_social_connectedness = read_social_connectedness(fpath_social_connectedness)

    for (fpath, country_code) ∈ zip(fpath_outputs, country_codes)
        if isfile(fpath) && !recreate
            return fpath
        end

        df_country_social_connectedness =
            inter_province_social_connectedness(df_social_connectedness, country_code)
        save_dataframe(df_country_social_connectedness, fpath)
    end

    return nothing
end

end # module FacebookData
