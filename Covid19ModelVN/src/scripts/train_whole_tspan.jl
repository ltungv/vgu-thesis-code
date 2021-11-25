include("include/cmd.jl")

runcmd(
    string.([
        "--beta_bounds",
        0.0,
        6.68 / 4,
        "--gamma0",
        1 / 4,
        "--gamma_bounds",
        1 / 4,
        1 / 4,
        "--lambda0",
        1 / 14,
        "--lambda_bounds",
        1 / 14,
        1 / 14,
        "--alpha_bounds",
        0.0,
        0.05,
        "--locations",
        # union(keys(Covid19ModelVN.LOC_NAMES_VN), keys(Covid19ModelVN.LOC_NAMES_US))...,
        "hcm",
        "--train_days=32",
        "--loss_type=sse",
        "--savedir=testsnapshots",
        "--show_progress",
        # "--multithreading",
        "fbmobility4",
        "train_whole_trajectory",
        "--lr=0.05",
        "--lr_limit=0.0001",
        "--lr_decay_rate=0.6",
        "--lr_decay_step=500",
        "--weight_decay=0.0001",
        "--maxiters=10000",
    ]),
)
