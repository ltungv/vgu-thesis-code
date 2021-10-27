module Helpers

export UDEDataset,
    moving_average!,
    train_test_split,
    load_timeseries,
    save_dataframe,
    Predictor,
    Loss,
    TrainCallback,
    TrainCallbackConfig,
    TrainSession,
    mae,
    mape,
    rmse,
    rmsle

using Dates,
    Serialization, Statistics, CSV, Plots, DataFrames, ProgressMeter, OrdinaryDiffEq

"""
This contains the minimum required information for a timeseriese dataset that is used by UDEs

# Fields

* `data`: an array that holds the timeseries data
* `tspan`: the first and last time coordinates of the timeseries data
* `tsteps`: collocations points
"""
struct UDEDataset
    data::AbstractArray{<:Real}
    tspan::Tuple{<:Real,<:Real}
    tsteps::Union{Real,AbstractVector{<:Real},StepRange,StepRangeLen}
end

"""
Calculate the moving average of the given list of numbers

# Arguments

+ `xs`: The list of number
+ `n`: Subset size to average over
"""
moving_average(xs, n) = [mean(@view xs[(i >= n ? i - n + 1 : 1):i]) for i = 1:length(xs)]

"""
Calculate the moving average of all the `cols` in `df`

# Arguments

+ `df`: A `DataFrame`
+ `cols`: Column names for calculating the moving average
+ `n`: Subset size to average over
"""
moving_average!(df, cols, n) =
    transform!(df, names(df, Cols(cols)) .=> x -> moving_average(x, n), renamecols = false)

"""
Filter the dataframe `df` by `col` such that its values remain between `start_date` and `end_date`

# Arguments

+ `df`: An arbitrary dataframe
+ `col`: The key column used for filtering
+ `first`: The starting (smallest) value allowed
+ `last`: The ending (largest) value allowed
"""
bound(df, col, first, last) =
    subset(df, col => x -> (x .>= first) .& (x .<= last), view = true)

"""
Create two `UDEDataset`s from the given dataframe, the first dataset contains data point whose `date_col`
value is in the range [first_date, split_date], and the second dataset contains data point whose `date_col`
value is in the range (split_date, last_date]

# Arguments

+ `df`: The dataframe
+ `data_cols`: The names of the columns whose data will be used for creating an array
+ `date_col`: The name of the column that contains the date of the data point
+ `first_date`: First date to take
+ `split_date`: Date where to dataframe is splitted in two
+ `last_date`: Last date to take
"""
function train_test_split(df, data_cols, date_col, first_date, split_date, last_date)
    df_train = bound(df, date_col, first_date, split_date)
    df_test = bound(df, date_col, split_date + Day(1), last_date)

    train_tspan = Float64.((0, Dates.value(split_date - first_date)))
    test_tspan = Float64.((0, Dates.value(last_date - first_date)))

    train_tsteps = train_tspan[1]:1:train_tspan[2]
    test_tsteps = (train_tspan[2]+1):1:test_tspan[2]

    train_data = Float64.(Array(df_train[!, data_cols])')
    test_data = Float64.(Array(df_test[!, data_cols])')

    train_dataset = UDEDataset(train_data, train_tspan, train_tsteps)
    test_dataset = UDEDataset(test_data, test_tspan, test_tsteps)

    return train_dataset, test_dataset
end

"""
Load from the time series in the dataframe the data from `data_cols` columns, limiting
the data point `date_col` between [`first_date`, `last_date`].

# Arguments

+ `df`: The dataframe
+ `data_cols`: The names of the columns whose data will be used for creating an array
+ `date_col`: The name of the column that contains the date of the data point
+ `first_date`: First date to take
+ `last_date`: Last date to take
"""
function load_timeseries(df, data_cols, date_col, first_date, last_date)
    df = bound(df, date_col, first_date, last_date)
    return Array(df[!, Cols(data_cols)])
end

"""
Save a dataframe as a CSV file

# Arguments

+ `df`: The dataframe to save
+ `fpath`: The path to save the file
"""
function save_dataframe(df, fpath)
    # create containing folder if not exists
    if !isdir(dirname(fpath))
        mkpath(dirname(fpath))
    end
    CSV.write(fpath, df)
    return fpath
end


"""
A struct that solves the underlying DiffEq problem and returns the solution when it is called

# Fields

* `problem`: the problem that will be solved
* `solver`: the numerical solver that will be used to calculate the DiffEq solution
"""
struct Predictor
    problem::ODEProblem
    solver::Any
end

"""
Construct a new `Predictor` with the solver set to the default value `Tsit5`

# Argument

+ `problem`: The `ODEProblem` that will be solved by the predictor object
"""
Predictor(problem::ODEProblem) = Predictor(problem, Tsit5())

"""
Call an object of struct `CovidModelPredict` to solve the underlying DiffEq problem

# Arguments

* `params`: the set of parameters of the system
* `tspan`: the time span of the problem
* `saveat`: the collocation coordinates
"""
function (p::Predictor)(params, tspan, saveat)
    problem = remake(p.problem, p = params, tspan = tspan)
    return solve(problem, p.solver, saveat = saveat)
end

"""
A callable struct that uses `metric_fn` to calculate the loss between the output of
`predict` and `dataset`.

# Fields

* `metric_fn`: a function that computes the error between two data arrays
* `predict_fn`: the time span that the ODE solver will be run on
* `dataset`: the dataset that contains the ground truth data
* `vars`: indices of the states that will be used to calculate the loss
"""
struct Loss
    metric_fn::Function
    predict_fn::Predictor
    dataset::UDEDataset
    vars::Union{Int,AbstractVector{Int},OrdinalRange}
end

"""
Call an object of the `Loss` struct on a set of parameters to get the loss scalar

# Arguments

* `params`: the set of parameters of the model
"""
function (l::Loss)(params)
    sol = l.predict_fn(params, l.dataset.tspan, l.dataset.tsteps)
    if sol.retcode != :Success
        # Unstable trajectories => hard penalize
        return Inf
    end

    pred = @view sol[l.vars, :]
    if size(pred) != size(l.dataset.data)
        # Unstable trajectories / Wrong inputs
        return Inf
    end

    return l.metric_fn(pred, l.dataset.data)
end

"""
Calculate the mean absolute error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
mae(ŷ, y) = mean(abs, (ŷ .- y))

"""
Calculate the mean absolute percentge error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
mape(ŷ, y) = 100 * mean(abs, (ŷ .- y) ./ y)

"""
Calculate the root mean squared error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
rmse(ŷ, y) = sqrt(mean(abs2, ŷ .- y))

"""
Calculate the root mean squared log error between 2 values. Note that the input arguments must be of the same size.
The function does not check if the inputs are valid and may produces erroneous output.
"""
rmsle(ŷ, y) = sqrt(mean(abs2, log.(ŷ .+ 1) .- log.(y .+ 1)))

"""
State of the callback struct

# Fields

* `iters`: number have iterations that have been run
* `progress`: the progress meter that keeps track of the process
* `train_losses`: collected training losses at each interval
* `test_losses`: collected testing losses at each interval
* `minimizer`: current best set of parameters
* `minimizer_loss`: loss value of the current best set of parameters
"""
mutable struct TrainCallbackState
    iters::Int
    progress::Progress
    train_losses::AbstractVector{<:Real}
    test_losses::AbstractVector{<:Real}
    minimizer::AbstractVector{<:Real}
    minimizer_loss::Real
end

"""
Construct a new `TrainCallbackState` with the progress bar set to `maxiters`
and other fields set to their default values

# Arguments

+ `maxiters`: Maximum number of iterrations that the optimizer will run
"""
TrainCallbackState(maxiters::Int) = TrainCallbackState(
    0,
    Progress(maxiters, showspeed = true),
    Float64[],
    Float64[],
    Float64[],
    Inf,
)

"""
Configuration of the callback struct

# Fields

* `test_loss_fn`: a callable for calculating the testing loss value
* `losses_plot_fpath`: file path to the saved losses figure
* `losses_plot_interval`: interval for collecting losses and plot the losses figure
* `params_save_fpath`: file path to the serialized current best set of parameters
* `params_save_interval`: interval for saving the current best set of parameters
"""
struct TrainCallbackConfig
    test_loss_fn::Union{Nothing,Loss}
    losses_plot_fpath::Union{Nothing,AbstractString}
    losses_plot_interval::Int
    params_save_fpath::Union{Nothing,AbstractString}
    params_save_interval::Int
end

"""
Contruct a default `TrainCallbackConfig`
"""
TrainCallbackConfig() =
    TrainCallbackConfig(nothing, nothing, typemax(Int), nothing, typemax(Int))

"""
A callable struct that is used for handling callback for `sciml_train`
"""
mutable struct TrainCallback
    state::TrainCallbackState
    config::TrainCallbackConfig
end

"""
Create a callback for `sciml_train`

# Arguments

* `maxiters`: max number of iterations the optimizer will run
* `config`: callback configurations
"""
TrainCallback(maxiters::Int, config::TrainCallbackConfig = TrainCallbackConfig()) =
    TrainCallback(TrainCallbackState(maxiters), config)

"""
Call an object of type `TrainCallback`

# Arguments

* `params`: the model's parameters
* `train_loss`: loss from the training step
"""
function (cb::TrainCallback)(params, train_loss)
    test_loss = if !isnothing(cb.config.test_loss_fn)
        cb.config.test_loss_fn(params)
    end

    if train_loss < cb.state.minimizer_loss
        cb.state.minimizer_loss = train_loss
        cb.state.minimizer = params
    end

    cb.state.iters += 1
    if cb.state.iters % cb.config.losses_plot_interval == 0 &&
       !isnothing(cb.config.losses_plot_fpath)
        append!(cb.state.train_losses, train_loss)
        append!(cb.state.test_losses, test_loss)
        plt = plot(
            [cb.state.train_losses, cb.state.test_losses],
            labels = ["train loss" "test loss"],
            legend = :outerright,
        )
        savefig(plt, cb.config.losses_plot_fpath)
    end
    if cb.state.iters % cb.config.params_save_interval == 0 &&
       !isnothing(cb.config.params_save_fpath)
        Serialization.serialize(cb.config.params_save_fpath, cb.state.minimizer)
    end

    next!(
        cb.state.progress,
        showvalues = [:train_loss => train_loss, :test_loss => test_loss],
    )
    return false
end

"""
Specifications for a model tranining session

# Arguments

+ `name`: Session name
+ `optimizer`: The optimizer that will run in the session
+ `maxiters`: Maximum number of iterations to run the optimizer
"""
struct TrainSession
    name::AbstractString
    optimizer::Any
    maxiters::Int
end

end
