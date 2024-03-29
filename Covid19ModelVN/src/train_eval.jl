"""
    Predictor{
        P<:SciMLBase.DEProblem,
        SO<:SciMLBase.DEAlgorithm,
        SE<:SciMLBase.AbstractSensitivityAlgorithm,
    }

A struct that solves the underlying DiffEq problem and returns the solution when it is called

# Fields

* `problem`: the problem that will be solved
* `solver`: the numerical solver that will be used to calculate the DiffEq solution
* `sensealg`: sensitivity algorithm for getting the local gradient
* `abstol`: solver's absolute tolerant
* `reltol`: solver's relative tolerant
+ `save_idxs`: the indices of the system's states to return

# Constructor

    Predictor(problem::SciMLBase.DEProblem, save_idxs::Vector{Int})

## Arguments

* `problem`: the problem that will be solved
+ `save_idxs`: the indices of the system's states to return
"""
struct Predictor{
    P<:SciMLBase.DEProblem,
    SO<:SciMLBase.DEAlgorithm,
    SE<:SciMLBase.AbstractSensitivityAlgorithm,
}
    problem::P
    solver::SO
    sensealg::SE
    abstol::Float64
    reltol::Float64
    save_idxs::Vector{Int}

    function Predictor(problem::SciMLBase.DEProblem, save_idxs::Vector{Int})
        solver = Tsit5()
        sensealg = InterpolatingAdjoint(; autojacvec=ReverseDiffVJP(true))
        return new{typeof(problem),typeof(solver),typeof(sensealg)}(
            problem, solver, sensealg, 1e-5, 1e-5, save_idxs
        )
    end
end

"""
    (p::Predictor)(params, tspan, saveat)

Call an object of struct `CovidModelPredict` to solve the underlying DiffEq problem

# Arguments

* `params`: the set of parameters of the system
* `tspan`: the time span of the problem
* `saveat`: the collocation coordinates
"""
function (p::Predictor)(params, tspan, saveat)
    problem = remake(p.problem; p=params, tspan=tspan)
    return solve(
        problem,
        p.solver;
        saveat=saveat,
        sensealg=p.sensealg,
        abstol=p.abstol,
        reltol=p.reltol,
        save_idxs=p.save_idxs,
    )
end

"""
    Loss{Metric,Predict,DataIter}

A callable struct that uses `metric` to calculate the loss between the output of
`predict` and `dataset`.

# Fields

* `metric`: a function that computes the error between two data arrays
* `predict`: the time span that the ODE solver will be run on
* `datacycle`: the cyling iterator that go through each batch in the dataset
* `tspan`: the integration time span

# Constructor

    Loss(
        metric,
        predict,
        dataset::TimeseriesDataset,
        batchsize = length(dataset.tsteps),
    )

## Arguments

* `metric`: a function that computes the error between two data arrays
* `predict`: the time span that the ODE solver will be run on
* `dataset`: the dataset that contains the ground truth data
* `batchsize`: the size of each batch in the dataset, default to no batching

# Callable

    (l::Loss{Metric,Predict,DataCycle})(
        params,
    ) where {Metric<:Function,Predict<:Predictor,DataCycle<:Iterators.Stateful,R<:Real}

Call an object of the `Loss` struct on a set of parameters to get the loss scalar.
Here, the field `metric` is used with 2 parameters: the prediction and the ground
truth data.

## Arguments

* `params`: the set of parameters of the model
"""
struct Loss{Reg,Metric,Predict,DataCycle}
    metric::Metric
    predict::Predict
    datacycle::DataCycle

    function Loss{false}(
        metric, predict, dataset::TimeseriesDataset, batchsize=length(dataset.tsteps)
    )
        dataloader = TimeseriesDataLoader(dataset, batchsize)
        datacycle = Iterators.Stateful(Iterators.cycle(dataloader))
        return new{false,typeof(metric),typeof(predict),typeof(datacycle)}(
            metric, predict, datacycle
        )
    end

    function Loss{true}(
        metric, predict, dataset::TimeseriesDataset, batchsize=length(dataset.tsteps)
    )
        dataloader = TimeseriesDataLoader(dataset, batchsize)
        datacycle = Iterators.Stateful(Iterators.cycle(dataloader))
        return new{true,typeof(metric),typeof(predict),typeof(datacycle)}(
            metric, predict, datacycle
        )
    end
end

function (l::Loss{false,Metric,Predict,DataCycle})(
    params
) where {Metric<:Function,Predict<:Predictor,DataCycle<:Iterators.Stateful}
    data, tspan, tsteps = popfirst!(l.datacycle)
    sol = l.predict(params, tspan, tsteps)
    if sol.retcode != :Success
        # Unstable trajectories
        return Inf
    end

    pred = @view sol[:, :]
    if size(pred) != size(data)
        # Unstable trajectories / Wrong inputs
        return Inf
    end
    return l.metric(pred, data)
end

function (l::Loss{true,Metric,Predict,DataCycle})(
    params
) where {Metric<:Function,Predict<:Predictor,DataCycle<:Iterators.Stateful}
    data, tspan, tsteps = popfirst!(l.datacycle)
    sol = l.predict(params, tspan, tsteps)
    if sol.retcode != :Success
        # Unstable trajectories
        return Inf
    end

    pred = @view sol[:, :]
    if size(pred) != size(data)
        # Unstable trajectories / Wrong inputs
        return Inf
    end
    return l.metric(pred, data, params, tsteps)
end

"""
    LogCallbackState{R<:Real}

State of the callback struct

# Fields

* `progress`: the progress meter that keeps track of the process
* `eval_losses`: collected evaluation losses at each interval
* `test_losses`: collected testing losses at each interval
* `minimizer`: current best set of parameters
* `minimizer_loss`: loss value of the current best set of parameters

# Constructor

    LogCallbackState(
        T::Type{R},
        params_length::Integer,
        show_progress::Bool,
    ) where {R<:Real} = new{T}(

## Arguments

+ `T`: type of the losses and parameters
+ `show_progress`: control whether to show a running progress bar

# Constructor

    LogCallbackState(
        T::Type{R},
        params_length::Integer,
        progress::ProgressUnknown,
    ) where {R<:Real} = LogCallbackState{T}(

## Arguments

+ `T`: type of the losses and parameters
+ `progress`: the progress meter object that will be used by the callback function
"""
mutable struct LogCallbackState{R<:Real}
    progress::ProgressUnknown
    eval_losses::Vector{R}
    test_losses::Vector{R}
    minimizer::Vector{R}
    minimizer_loss::R

    function LogCallbackState(
        t::Type{R}, params_length::Integer, show_progress::Bool
    ) where {R<:Real}
        return LogCallbackState(
            t, params_length, ProgressUnknown(; showspeed=true, enabled=show_progress)
        )
    end

    function LogCallbackState(
        t::Type{R}, params_length::Integer, progress::ProgressUnknown
    ) where {R<:Real}
        return new{t}(progress, t[], t[], Vector{t}(undef, params_length), typemax(t))
    end
end

"""
    LogCallbackConfig{L<:Loss}

Configuration of the callback struct

# Fields

* `eval_loss`: loss function on the train dataset
* `test_loss`: loss function on the test dataset
* `losses_save_fpath`: file path to the saved losses figure
* `params_save_fpath`: file path to the serialized current best set of parameters
"""
struct LogCallbackConfig{L1<:Loss,L2<:Loss}
    eval_loss::L1
    test_loss::L2
    losses_save_fpath::String
    params_save_fpath::String
end

"""
    LogCallback{R<:Real,L<:Loss}

A callable struct that is used for handling callback for `sciml_train`. The callback will
keep track of the losses, the minimizer, and show a progress that keeps track of the
training process

# Fields

* `state`: current state of the object
* `config`: callback configuration

# Callable

    (cb::LogCallback)(params::AbstractVector{R}, train_loss::R) where {R<:Real}

# Arguments

* `params`: the model's parameters
* `train_loss`: loss from the training step
"""
struct LogCallback
    state::LogCallbackState
    config::LogCallbackConfig
end

function (cb::LogCallback)(params::AbstractVector{R}, train_loss::R) where {R<:Real}
    eval_loss = cb.config.eval_loss(params)
    test_loss = cb.config.test_loss(params)
    showvalues = @SVector [
        :losses_save_fpath => cb.config.losses_save_fpath,
        :params_save_fpath => cb.config.params_save_fpath,
        :train_loss => train_loss,
        :eval_loss => eval_loss,
        :test_loss => test_loss,
    ]
    next!(cb.state.progress; showvalues=showvalues)
    push!(cb.state.eval_losses, eval_loss)
    push!(cb.state.test_losses, test_loss)
    if eval_loss < cb.state.minimizer_loss && size(params) == size(cb.state.minimizer)
        cb.state.minimizer_loss = eval_loss
        cb.state.minimizer .= params
    end
    Serialization.serialize(
        cb.config.losses_save_fpath, (cb.state.eval_losses, cb.state.test_losses)
    )
    Serialization.serialize(cb.config.params_save_fpath, cb.state.minimizer)
    return false
end

"""
    EvalConfig

A struct for holding general configuration for the evaluation process

# Arguments

+ `metrics`: a list of metric function that will be used to compute the model errors
+ `forecast_ranges`: a list of different time ranges on which the model's prediction will be evaluated
+ `labels`: names of the evaluated model's states
"""
struct EvalConfig
    metrics::Vector{Function}
    forecast_ranges::Vector{Int}
    labels::Vector{String}
end

"""
    ForecastsAnimationCallback{Predict<:Predictor}

A callable struct that is used for handling callback for `sciml_train`. The callback will
use the parameters returned from `sciml_train` to make forecasts and create a animation of
the model's learning process.

# Fields

* `vs`: the video stream object from `Makie`
* `fig`: the figure that is shown in the animation
* `model_fit`: an observable object that keeps track of the model's fit
* `model_pred`: an observable object that keeps track of the model's extrapolation
* `train_dataset`: ground truth data for fitting
* `test_dataset`: ground truth data for the extrapolation
* `predictor`: an object of struct `Predictor` that produce the model's output

# Constructor

    ForecastsAnimationCallback(
        predictor::Predictor,
        p0::AbstractVector{<:Real},
        train_dataset::TimeseriesDataset,
        test_dataset::TimeseriesDataset,
        eval_config::EvalConfig;
        kwargs...,
    )

## Arguments

* `predictor`: an object of struct `Predictor` that produce the model's output
* `p0`: the model's initial set of parameters
* `train_dataset`: ground truth data for fitting
* `test_dataset`: ground truth data for the extrapolation
* `eval_config`: configuration for creating the forecast plot
* `kwargs`: keyword arguments that will be splatted to `Makie.VideoStream`

# Callable

    (cb::ForecastsAnimationCallback)(params)

# Arguments

* `params`: the model's parameters
"""
struct ForecastsAnimationCallback{Predict<:Predictor}
    vs::VideoStream
    fig::Figure
    model_fit::Observable
    model_pred::Observable
    train_dataset::TimeseriesDataset
    test_dataset::TimeseriesDataset
    predictor::Predict

    function ForecastsAnimationCallback(
        predictor::Predictor,
        p0::AbstractVector{<:Real},
        train_dataset::TimeseriesDataset,
        test_dataset::TimeseriesDataset,
        eval_config::EvalConfig;
        kwargs...,
    )
        model_fit = Node(predictor(p0, train_dataset.tspan, train_dataset.tsteps))
        model_pred = Node(predictor(p0, test_dataset.tspan, test_dataset.tsteps))
        fig = plot_forecasts(
            eval_config, model_fit, model_pred, train_dataset, test_dataset
        )
        vs = VideoStream(fig; kwargs...)
        return new{typeof(predictor)}(
            vs, fig, model_fit, model_pred, train_dataset, test_dataset, predictor
        )
    end
end

function (cb::ForecastsAnimationCallback)(params)
    cb.model_fit[] = cb.predictor(params, cb.train_dataset.tspan, cb.train_dataset.tsteps)
    cb.model_pred[] = cb.predictor(params, cb.test_dataset.tspan, cb.test_dataset.tsteps)
    autolimits!.(contents(cb.fig[:, :]))
    recordframe!(cb.vs)
    return false
end

mutable struct ForecastsCallbackState{R<:Real}
    fit::Vector{Matrix{R}}
    pred::Vector{Matrix{R}}

    ForecastsCallbackState(t::Type{R}) where {R<:Real} = new{t}(Matrix{t}[], Matrix{t}[])
end

struct ForecastsCallbackConfig{Predict<:Predictor}
    predictor::Predict
    train_dataset::TimeseriesDataset
    test_dataset::TimeseriesDataset
    forecasts_save_fpath::String
end

struct ForecastsCallback{R<:Real,Predict<:Predictor}
    state::ForecastsCallbackState{R}
    config::ForecastsCallbackConfig{Predict}
end

function (cb::ForecastsCallback)(params)
    fit = cb.config.predictor(
        params, cb.config.train_dataset.tspan, cb.config.train_dataset.tsteps
    )
    pred = cb.config.predictor(
        params, cb.config.test_dataset.tspan, cb.config.test_dataset.tsteps
    )
    @views push!(cb.state.fit, fit[:, :])
    @views push!(cb.state.pred, pred[:, :])
    Serialization.serialize(cb.config.forecasts_save_fpath, (cb.state.fit, cb.state.pred))
    return false
end

"""
    evaluate_model(
        config::EvalConfig,
        predictor::Predictor,
        params::AbstractVector{<:Real},
        train_dataset::TimeseriesDataset,
        test_dataset::TimeseriesDataset,
    )::(Makie.Figure, DataFrames.DataFrame)

Evaluate the model by calculating the errors and draw plot againts ground truth data

# Returns

A 2-tuple where the first element contains the Figure object containing the model
forecasts and the second element contains the Dataframe fore the forecasts errors

# Arguments

+ `config`: the configuration for the evalution process
+ `predictor`: the function that produce the model's prediction
+ `params`: the parameters used for making the predictions
+ `train_dataset`: ground truth data on which the model was trained
+ `test_dataset`: ground truth data that the model has not seen
"""
function evaluate_model(
    config::EvalConfig,
    predictor::Predictor,
    params::AbstractVector{<:Real},
    train_dataset::TimeseriesDataset,
    test_dataset::TimeseriesDataset,
)
    fit = predictor(params, train_dataset.tspan, train_dataset.tsteps)
    pred = predictor(params, test_dataset.tspan, test_dataset.tsteps)
    forecasts_plot = plot_forecasts(config, fit, pred, train_dataset, test_dataset)
    df_forecasts_errors = calculate_forecasts_errors(config, pred, test_dataset)
    df_time_steps_errors = calculate_time_steps_mae(config.labels, pred, test_dataset)
    return forecasts_plot, df_forecasts_errors, df_time_steps_errors
end

"""
    calculate_forecasts_errors(
        config::EvalConfig,
        pred,
        test_dataset::TimeseriesDataset,
    )::DataFrame

Calculate the forecast error based on the model prediction and the ground truth data
for each forecasting horizon

# Returns

A dataframe containing the errors between the model prediction and the ground truth data
calculated with different metrics and forecasting horizons

# Arguments

* `config`: configuration for evaluation
* `pred`: prediction made by the model
* `test_dataset`: ground truth data for the forecasted period
"""
function calculate_forecasts_errors(
    config::EvalConfig, pred, test_dataset::TimeseriesDataset
)
    horizons = repeat(config.forecast_ranges; inner=length(config.metrics))
    metrics = repeat(map(string, config.metrics), length(config.forecast_ranges))
    errors = reshape(
        [
            metric(pred[idx, 1:days], test_dataset.data[idx, 1:days]) for
            metric in config.metrics, days in config.forecast_ranges,
            idx in 1:length(config.labels)
        ],
        length(config.metrics) * length(config.forecast_ranges),
        length(config.labels),
    )
    df1 = DataFrame([horizons metrics], [:horizon, :metric])
    df2 = DataFrame(errors, config.labels)
    return [df1 df2]
end

function calculate_time_steps_mae(labels, pred, test_dataset::TimeseriesDataset)
    errors = abs.(pred .- test_dataset.data)
    return DataFrame(errors', labels)
end

"""
    MakieShowoffPlain

Marker struct for our custom formatter that uses `Showoff.showoff` with the option set to
`:plain`. This is done to mitigate to error occur with `Unicode.subscript` when used on
scientific-/engineering-formated strings
"""
struct MakieShowoffPlain end

"""
    makie_log_scale_formatter(xs::AbstractVector)::Vector{String}

The format function that is used when the `MakieLogScaleFormatter` marker is set
"""
makie_showoff_plain(xs) = MakieLayout.Showoff.showoff(xs, :plain)

"""
    MakieLayout.get_ticks(l::LogTicks, scale::Union{typeof(log10), typeof(log2), typeof(log)}, ::MakieShowoffPlain, vmin, vmax)

Override Makie default function for getting ticks values and labels for log-scaled axis.
This method uses our custom formatter `MakieShowoffPlain` instead of using `Makie.Automatic`.
"""
function MakieLayout.get_ticks(
    l::LogTicks,
    scale::Union{typeof(log10),typeof(log2),typeof(log)},
    ::MakieShowoffPlain,
    vmin,
    vmax,
)
    ticks_scaled = MakieLayout.get_tickvalues(
        l.linear_ticks, identity, scale(vmin), scale(vmax)
    )
    ticks = Makie.inverse_transform(scale).(ticks_scaled)

    labels_scaled = MakieLayout.get_ticklabels(makie_showoff_plain, ticks_scaled)
    labels = MakieLayout._logbase(scale) .* Makie.UnicodeFun.to_superscript.(labels_scaled)

    return (ticks, labels)
end

"""
    plot_losses(
        train_losses::AbstractVector{R},
        test_losses::AbstractVector{R},
    ) where {R<:Real}

Illustrate the training andd testing losses using a twinaxis plot

# Arguments

*`train_losses`: the training losses to be plotted
*`test_losses`: the testing losses to be plotted
"""
function plot_losses(
    train_losses::AbstractVector{R}, test_losses::AbstractVector{R}
) where {R<:Real}
    fig = Figure()
    ax1 = Axis(
        fig[1, 1];
        title="Losses of the model after each iteration",
        xlabel="Iterations",
        yscale=log10,
        ytickformat=MakieShowoffPlain(),
        yticklabelcolor=Makie.ColorSchemes.tab10[1],
    )
    ax2 = Axis(
        fig[1, 1];
        yaxisposition=:right,
        yscale=log10,
        ytickformat=MakieShowoffPlain(),
        yticklabelcolor=Makie.ColorSchemes.tab10[2],
    )
    hidespines!(ax2)
    hidexdecorations!(ax2)
    ln1 = lines!(ax1, train_losses; color=Makie.ColorSchemes.tab10[1], linewidth=3)
    ln2 = lines!(ax2, test_losses; color=Makie.ColorSchemes.tab10[2], linewidth=3)
    Legend(
        fig[1, 1],
        [ln1, ln2],
        ["Train loss", "Test loss"];
        margin=(10, 10, 10, 10),
        tellheight=false,
        tellwidth=false,
        halign=:right,
        valign=:top,
    )
    return fig
end

function plot_losses(train_losses::AbstractVector{R}) where {R<:Real}
    fig = Figure()
    ax = Axis(
        fig[1, 1];
        title="Losses of the model after each iteration",
        xlabel="Iterations",
        yscale=log10,
    )
    ln = lines!(ax, train_losses; color=Makie.ColorSchemes.tab10[1], linewidth=3)
    Legend(
        fig[1, 1],
        [ln],
        ["Train loss"];
        margin=(10, 10, 10, 10),
        tellheight=false,
        tellwidth=false,
        halign=:right,
        valign=:top,
    )
    return fig
end

"""
    plot_forecasts(
        config::EvalConfig,
        fit,
        pred,
        train_dataset::TimeseriesDataset,
        test_dataset::TimeseriesDataset,
    )

Plot the forecasted values produced by against the ground truth data.

# Returns

The figure object from Makie that contains the plotting definition for the model predictions

# Arguments

* `config`: configuration for evaluation
* `fit`: the solution returned by the model on the fit data
* `pred`: prediction made by the model
* `train_dataset`: the data that was used to train the model
* `test_dataset`: ground truth data for the forecasted period
"""
function plot_forecasts(
    config::EvalConfig,
    fit,
    pred,
    train_dataset::TimeseriesDataset,
    test_dataset::TimeseriesDataset,
)
    fig = Figure(;
        resolution=(400 * length(config.forecast_ranges), 400 * length(config.labels))
    )
    for (i, label) in enumerate(config.labels),
        (j, days) in enumerate(config.forecast_ranges)

        truth = @views [train_dataset.data[i, :]; test_dataset.data[i, 1:days]]
        output = [fit[i, :]; pred[i, 1:days]]
        plot_forecast!(fig[i, j], output, truth, days, train_dataset.tspan[2], label)
    end
    return fig
end

function plot_forecasts(
    config::EvalConfig,
    fit::Observable,
    pred::Observable,
    train_dataset::TimeseriesDataset,
    test_dataset::TimeseriesDataset,
)
    fig = Figure(;
        resolution=(400 * length(config.forecast_ranges), 400 * length(config.labels))
    )
    for (i, label) in enumerate(config.labels),
        (j, days) in enumerate(config.forecast_ranges)

        truth = @views [train_dataset.data[i, :]; test_dataset.data[i, 1:days]]
        output = lift(fit, pred) do x, y
            @views [x[i, :]; y[i, 1:days]]
        end
        plot_forecast!(fig[i, j], output, truth, days, train_dataset.tspan[2], label)
    end
    return fig
end

function plot_forecast!(
    gridpos::GridPosition, output, truth, days::Real, sep::Real, label::AbstractString
)
    ax = Axis(
        gridpos;
        title="$days-day forecast",
        xlabel="Days since the 500th confirmed cases",
        ylabel="Cases",
    )
    ylims_offset = (maximum(truth) - minimum(truth)) * 0.05
    ylims!(ax, minimum(truth) - ylims_offset, maximum(truth) + ylims_offset)
    vlines!(ax, [sep]; color=:black, linestyle=:dash)
    lines!(ax, truth; label=label, linewidth=4, color=Makie.ColorSchemes.tab10[1])
    lines!(ax, output; label="prediction", linewidth=4, color=Makie.ColorSchemes.tab10[2])
    axislegend(ax; position=:lt, bgcolor=(:white, 0.7))
    return ax
end

"""
    plot_Re(Re::AbstractVector{R}, sep::R)::Figure where {R<:Real}

Plot the effective reproduction number for the traing period and testing period

# Returns

The figure object from Makie that contains the plotting definition for the given
effecitve reproduction number

# Arguments

* `Re`: the effective reproduction number
* `sep`: value at which the data is splitted for training and testing
"""
function plot_Re(Re::AbstractVector{R}, sep::R) where {R<:Real}
    fig = Figure(; resolution=(400, 400))
    ax = Axis(
        fig[1, 1];
        xlabel="Days since the 500th confirmed case",
        ylabel="Effective reproduction number",
    )
    vlines!(ax, [sep]; color=:black, linestyle=:dash)
    hlines!(
        ax,
        [1];
        color=:green,
        linestyle=:dash,
        linewidth=3,
        label="threshold",
    )
    lines!(ax, Re; color=:black, linewidth=3)
    axislegend(ax; position=:rt, bgcolor=(:white, 0.7))
    return fig
end

function plot_fatality_rate(αt::AbstractVector{R}, sep::R) where {R<:Real}
    fig = Figure(; resolution=(400, 400))
    ax = Axis(
        fig[1, 1]; xlabel="Days since the 500th confirmed case", ylabel="Fatality rate (%)"
    )
    vlines!(ax, [sep]; color=:black, linestyle=:dash)
    lines!(ax, αt; color=:red, linewidth=3)
    return fig
end

"""
    logit(x::Real)::Real

Calculate the inverse of the sigmoid function
"""
logit(x::Real) = log(x / (1 - x))

"""
    boxconst(x::Real, bounds::Tuple{R,R})::Real where {R<:Real}

Transform the value of `x` to get a value that lies between `bounds[1]` and `bounds[2]`
"""
function boxconst(x::Real, bounds::Tuple{R,R}) where {R<:Real}
    return bounds[1] + (bounds[2] - bounds[1]) * sigmoid(x)
end

"""
    boxconst(x::Real, bounds::Tuple{R,R})::Real where {R<:Real}

Calculate the inverse of the `boxconst` function
"""
function boxconst_inv(x::Real, bounds::Tuple{R,R}) where {R<:Real}
    return logit((x - bounds[1]) / (bounds[2] - bounds[1]))
end

"""
    hswish(x::Real)::Real

[1] A. Howard et al., “Searching for MobileNetV3,” arXiv:1905.02244 [cs], Nov. 2019, Accessed: Oct. 09, 2021. [Online]. Available: http://arxiv.org/abs/1905.02244
"""
hswish(x::Real) = x * (relu6(x + 3) / 6)

"""
    mae(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real})::Real

Calculate the mean absolute error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
mae(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real}) = mean(abs, (ŷ .- y))

"""
    sse(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real})::Real

Calculate the sum squared error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
sse(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real}) = sum(abs2, (ŷ .- y))

"""
    mape(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real})::Real

Calculate the mean absolute percentge error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
mape(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real}) = 100 * mean(abs, (ŷ .- y) ./ y)

"""
    rmse(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real})::Real

Calculate the root mean squared error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
rmse(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real}) = sqrt(mean(abs2, ŷ .- y))

"""
    rmsle(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real})::Real

Calculate the root mean squared log error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
function rmsle(ŷ::AbstractArray{<:Real}, y::AbstractArray{<:Real})
    return sqrt(mean(abs2, log.(ŷ .+ 1) .- log.(y .+ 1)))
end
