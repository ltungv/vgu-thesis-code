export get_model_initial_params,
    CovidModelSEIRDBaseline, CovidModelSEIRDFbMobility1, CovidModelSEIRDFbMobility2

using OrdinaryDiffEq, DiffEqFlux

"""
A struct for containing the SEIRD baseline model

# Fields

* `β_ann`: an neural network that outputs the time-dependent β contact rate
* `problem`: the ODE problem to be solved
"""
struct CovidModelSEIRDBaseline
    β_ann::FastChain
    problem::ODEProblem
end

"""
Construct the default SEIRD baseline model

# Arguments

* `u0`: the system initial conditions
* `tspan`: the time span in which the system is considered
"""
function CovidModelSEIRDBaseline(u0::Vector{<:Real}, tspan::Tuple{<:Real,<:Real})
    # small neural network and can be trained faster on CPU
    β_ann =
        FastChain(FastDense(2, 8, relu), FastDense(8, 8, relu), FastDense(8, 1, softplus))
    # system dynamics
    function dudt!(du::Vector{<:Real}, u::Vector{<:Real}, p::Vector{<:Real}, t::Real)
        @inbounds begin
            S, E, I, _, _, _, N = u
            γ, λ, α = abs.(@view(p[1:3]))

            # infection rate depends on time, susceptible, and infected
            β = first(β_ann([S / N; I / N], @view p[4:end]))

            du[1] = -β * S * I / N
            du[2] = β * S * I / N - γ * E
            du[3] = γ * E - λ * I
            du[4] = (1 - α) * λ * I
            du[5] = α * λ * I
            du[6] = γ * E
            du[7] = -α * λ * I
        end
        nothing
    end
    prob = ODEProblem(dudt!, u0, tspan)
    return CovidModelSEIRDBaseline(β_ann, prob)
end

"""
Get the initial set of parameters of the baselien SEIRD model with Facebook movement range
"""
get_model_initial_params(model::CovidModelSEIRDBaseline) =
    [1 / 2; 1 / 4; 0.025; initial_params(model.β_ann)]

"""
A struct for containing the SEIRD model with Facebook movement range

# Fields

* `β_ann`: an neural network that outputs the time-dependent β contact rate
* `problem`: the ODE problem to be solved
"""
struct CovidModelSEIRDFbMobility1
    β_ann::FastChain
    problem::ODEProblem
end

"""
Construct the default SEIRD model with Facebook movement range data

# Arguments

* `u0`: the system initial conditions
* `tspan`: the time span in which the system is considered
* `movement_range_data`: the matrix for the Facebook movement range timeseries data
"""
function CovidModelSEIRDFbMobility1(
    u0::Vector{<:Real},
    tspan::Tuple{<:Real,<:Real},
    movement_range_data::Matrix{<:Real},
)
    # small neural network and can be trained faster on CPU
    β_ann =
        FastChain(FastDense(4, 8, relu), FastDense(8, 8, relu), FastDense(8, 1, softplus))
    # system dynamics
    function dudt!(du::Vector{<:Real}, u::Vector{<:Real}, p::Vector{<:Real}, t::Real)
        @inbounds begin
            S, E, I, _, _, _, N = u
            γ, λ, α = abs.(@view(p[1:3]))

            # daily mobility
            mobility = movement_range_data[Int(floor(t + 1)), :]
            # infection rate depends on time, susceptible, and infected
            β = first(β_ann([S / N; I / N; mobility...], @view p[4:end]))

            du[1] = -β * S * I / N
            du[2] = β * S * I / N - γ * E
            du[3] = γ * E - λ * I
            du[4] = (1 - α) * λ * I
            du[5] = α * λ * I
            du[6] = γ * E
            du[7] = -α * λ * I
        end
        return nothing
    end
    prob = ODEProblem(dudt!, u0, tspan)
    return CovidModelSEIRDFbMobility1(β_ann, prob)
end

"""
Get the initial set of parameters of the SEIRD model with Facebook movement range
"""
get_model_initial_params(model::CovidModelSEIRDFbMobility1) =
    [1 / 2; 1 / 4; 0.025; initial_params(model.β_ann)]

"""
A struct for containing the SEIRD model with Facebook movement range

# Fields

* `β_ann`: an neural network that outputs the time-dependent β contact rate
* `problem`: the ODE problem to be solved
"""
struct CovidModelSEIRDFbMobility2
    β_ann::FastChain
    problem::ODEProblem
end

"""
Construct the default SEIRD model with Facebook movement range data
and social connectedness

# Arguments

* `u0`: the system initial conditions
* `tspan`: the time span in which the system is considered
* `movement_range_data`: the matrix for the Facebook movement range timeseries data
"""
function CovidModelSEIRDFbMobility2(
    u0::Vector{<:Real},
    tspan::Tuple{<:Real,<:Real},
    movement_range_data::Matrix{<:Real},
    spc_data::Matrix{<:Real},
)
    # small neural network and can be trained faster on CPU
    β_ann =
        FastChain(FastDense(5, 8, relu), FastDense(8, 8, relu), FastDense(8, 1, softplus))
    # system dynamics
    function dudt!(du::Vector{<:Real}, u::Vector{<:Real}, p::Vector{<:Real}, t::Real)
        @inbounds begin
            S, E, I, _, _, _, N = u
            γ, λ, α = abs.(@view(p[1:3]))

            # daily mobility
            time_idx = Int(floor(t + 1))
            mobility = movement_range_data[time_idx, :]
            spc = spc_data[time_idx]
            # infection rate depends on time, susceptible, and infected
            β = first(β_ann([S / N; I / N; spc; mobility...], @view p[4:end]))

            du[1] = -β * S * I / N
            du[2] = β * S * I / N - γ * E
            du[3] = γ * E - λ * I
            du[4] = (1 - α) * λ * I
            du[5] = α * λ * I
            du[6] = γ * E
            du[7] = -α * λ * I
        end
        return nothing
    end
    prob = ODEProblem(dudt!, u0, tspan)
    return CovidModelSEIRDFbMobility2(β_ann, prob)
end

"""
Get the initial set of parameters of the SEIRD model with Facebook movement range
"""
get_model_initial_params(model::CovidModelSEIRDFbMobility2) =
    [1 / 2; 1 / 4; 0.025; initial_params(model.β_ann)]
