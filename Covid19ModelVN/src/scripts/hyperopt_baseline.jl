include("include/experiments.jl")

using Hyperopt
using Statistics

let
    savedir = "snapshots/baseline/hyperopt"
    locations = [
        Covid19ModelVN.LOC_CODE_VIETNAM
        Covid19ModelVN.LOC_CODE_UNITED_STATES
        collect(keys(Covid19ModelVN.LOC_NAMES_VN))
        collect(keys(Covid19ModelVN.LOC_NAMES_US))
    ]

    ho = @hyperopt for i in 100, # number of samples
        sampler in Hyperband(R = 50, η = 3, inner = RandomSampler()),
        ζ in [-exp10.(-3:-1); 0.0; exp10.(-3:-1)],
        adam_lr in [exp10.(-4:-2); exp10.(-4:-2) .* 5],
        adam_maxiters in exp10(3) .* (2:2:20),
        bfgs_initial_stepnorm in exp10.(-3:-2),
        bfgs_maxiters in exp10(2) .* (2:4:10)

        minimizers, final_losses = experiment_run(
            "baseline",
            setup_baseline,
            locations,
            (
                ζ = ζ,
                γ0 = 1 / 3,
                λ0 = 1 / 14,
                α0 = 0.025,
                γ_bounds = (1 / 5, 1 / 2),
                λ_bounds = (1 / 21, 1 / 7),
                α_bounds = (0.0, 0.06),
                train_range = Day(32),
                forecast_range = Day(28),
            ),
            TrainConfig[
                TrainConfig("ADAM", ADAM(adam_lr), Int(adam_maxiters)),
                TrainConfig(
                    "BFGS",
                    BFGS(initial_stepnorm = bfgs_initial_stepnorm),
                    Int(bfgs_maxiters),
                ),
            ];
            savedir,
        )
        mean(final_losses), minimizers
    end
    show(ho)

    fig = Figure(resolution = (600, 400 * length(ho.params)))
    for (paramid, param) in enumerate(ho.params)
        ax = Axis(fig[paramid, 1], xlabel = string(param), ylabel = "Loss")
        scatter!(ax, map(h -> h[paramid], ho.history), Float64.(ho.results))
    end
    display(fig)
end