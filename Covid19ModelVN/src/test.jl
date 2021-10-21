# Activate the environment for running the script
if isfile("Project.toml") && isfile("Manifest.toml")
    import Pkg
    Pkg.activate(".")
end

using Covid19ModelVN.Datasets

const DEFAULT_DATASETS_DIR = "datasets"


DEFAULT_VIETNAM_GADM1_POPULATION_DATASET(DEFAULT_DATASETS_DIR)
DEFAULT_VIETNAM_COVID_DATA_TIMESERIES(DEFAULT_DATASETS_DIR)
DEFAULT_VIETNAM_PROVINCES_CONFIRMED_TIMESERIES(DEFAULT_DATASETS_DIR)
DEFAULT_VIETNAM_PROVINCES_TOTAL_CONFIRMED_TIMESERIES(DEFAULT_DATASETS_DIR)

DEFAULT_VIETNAM_PROVINCE_CONFIRMED_AND_DEATHS_TIMESERIES(DEFAULT_DATASETS_DIR, "HoChiMinh")
DEFAULT_VIETNAM_PROVINCE_CONFIRMED_AND_DEATHS_TIMESERIES(DEFAULT_DATASETS_DIR, "BinhDuong")
DEFAULT_VIETNAM_PROVINCE_CONFIRMED_AND_DEATHS_TIMESERIES(DEFAULT_DATASETS_DIR, "DongNai")
DEFAULT_VIETNAM_PROVINCE_CONFIRMED_AND_DEATHS_TIMESERIES(DEFAULT_DATASETS_DIR, "LongAn")

DEFAULT_VIETNAM_AVERAGE_MOVEMENT_RANGE(DEFAULT_DATASETS_DIR)
DEFAULT_VIETNAM_PROVINCE_AVERAGE_MOVEMENT_RANGE(DEFAULT_DATASETS_DIR, 26)
DEFAULT_VIETNAM_INTRA_CONNECTEDNESS_INDEX(DEFAULT_DATASETS_DIR)
DEFAULT_VIETNAM_SOCIAL_PROXIMITY_TO_CASES_INDEX(DEFAULT_DATASETS_DIR)