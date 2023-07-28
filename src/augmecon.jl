"""
    augmecon(model::Model, objectives::Vector{VariableRef}, grid_points::Int64)

Solve a JuMP model using the AUGMECON method with the specified optimizer.

# Arguments:
- `model::Model`: The JuMP model to be solved with AUGMECON.
- `objectives::Vector{VariableRef}`: A vector of variables representing the objectives of the model.
- `grid_points::Int64`: The number of grid points used in the AUGMECON method.
- `objective_sense_set::Vector{String}`: A vector of strings specifying the objective senses for each objective. Default value is `["Max" for i in eachindex(objectives)]`, indicating that all objectives are to be maximized. Use `"Max"` for maximization and `"Min"` for minimization.
- `penalty::Float64`: (Optional) Penalty parameter for AUGMECON method. Default value is `1e-3`, which falls within the recommended interval suggested by the authors, between `1e-3` and `1e-6`.
- `augmecon_2::Bool`: (Optional) If set to `true` (default), AUGMECON will use its second version (augmecon_2) to solve the model. Set to `false` to use the original AUGMECON algorithm.

# Returns:
- `frontier`: An array containing the optimal solutions forming the Pareto frontier.
- `solve_report`: A report containing additional information about the optimization process.

# Examples
```julia
using JuMP
using HiGHS

# Create a JuMP model
model = Model(HiGHS.Optimizer)
@variables model begin
    x[1:2] >= 0
    objs[1:2]
end 
@constraints model begin
    c1, x[1] <= 20
    c2, x[2] <= 40
    c3, 5*x[1] + 4*x[2] <= 200
    objective_1, objs[1] == x[1]
    objective_2, objs[2] == 3*x[1] + 4*x[2]
end

# Solve the model using AUGMECON method
frontier, solve_report = augmecon(model, objs, grid_points = 10, objective_sense_set = ["Max", "Max"])
```
"""
function augmecon(model::Model, objectives::Vector{VariableRef}, grid_points::Int64; user_options...)
    @assert length(objectives) >= 2 "The model has only 1 objective"
    @assert all(JuMP.is_valid.(Ref(model), objectives)) "At least one objective isn't defined in the model as a constraint"

    options = augmecon_options(grid_points, length(objectives), user_options) 
    start_augmecon_time = tic()
    augmecon_model = AugmeconJuMP(model, objectives, options)
    objectives_rhs = get_objectives_rhs(augmecon_model, options)
    set_model_for_augmecon!(augmecon_model, objectives_rhs, options)
    
    solve_report = augmecon_model.report
    start_recursion_time = tic()
    frontier = SolutionJuMP[]
    if options[:bypass]
        s_2 = augmecon_model.model[:s][2]
        recursive_augmecon2!(augmecon_model, frontier, objectives_rhs, s_2 = s_2)
    else
        recursive_augmecon!(augmecon_model, frontier, objectives_rhs)
    end

    solve_report.counter["recursion_total_time"] = toc(start_recursion_time)
    solve_report.counter["total_time"] = toc(start_augmecon_time)
    convert_table_to_correct_sense!(augmecon_model)
    return generate_pareto(frontier), solve_report
end

function get_objectives_rhs(augmecon_model, options)
    if :nadir in keys(options)
        ideal_point = get_ideal_point(augmecon_model)
        return set_objectives_rhs_range(ideal_point, options)
    end
    payoff_table!(augmecon_model) 
    return set_objectives_rhs_range(augmecon_model)
end

function get_ideal_point(augmecon_model)
    objectives = augmecon_model.objectives_maximize

    start_time = tic()
    ideal_point = zeros(length(objectives))
    for i in 2:length(ideal_point)
        obj = objectives[i]
        optimize_and_fix!(augmecon_model, obj)
        ideal_point[i] = lower_bound(obj)
        delete_lower_bound(obj)
    end
    solve_report = augmecon_model.report
    solve_report.counter["tables_generation_total_time"] = toc(start_time)
    @objective(augmecon_model.model, Max, 0.0)
    # println(ideal_point)
    return ideal_point
end

function set_objectives_rhs_range(ideal_point, options)
    nadir = options[:nadir]

    # println(nadir)
    verify_nadir(ideal_point, nadir)
    return [
        range(nadir[o], ideal_point[o], length = ((ideal_point[o] - nadir[o]) != 0.0 ? options[:grid_points] : 1)) 
            for o in eachindex(ideal_point)
    ]
end

function verify_nadir(ideal_point, nadir)
    for (o, value) in enumerate(ideal_point)
        @assert nadir[o] <= value "nadir is better than ideal point in at least $o"
    end
    return nothing
end


###############################
###############################

function verify_objectives_sense_set(objective_sense_set, objectives)
    for sense in objective_sense_set
        @assert (sense == "Max" || sense == "Min") """Objective sense should be "Max" or "Min" """
    end
    @assert length(objectives) == length(objective_sense_set) """Number of objectives ($(length(objectives))) is different than the length of objective_sense_set ($(length(objective_sense_set)))"""
    return nothing
end

###############################
###############################

function payoff_table!(augmecon_model::AugmeconJuMP)
    objectives = augmecon_model.objectives_maximize
    start_time = tic()
    solve_report = augmecon_model.report
    table = solve_report.table
    for (i, obj_higher) in enumerate(objectives)
        optimize_and_fix!(augmecon_model, obj_higher)
        for (o, obj_minor) in enumerate(objectives)
            if i != o
                optimize_and_fix!(augmecon_model, obj_minor)
            end
        end
        save_on_table!(table, i, augmecon_model)
        delete_lower_bound.(objectives)
    end
    solve_report.counter["tables_generation_total_time"] = toc(start_time)
    @objective(augmecon_model.model, Max, 0.0)
    return table
end

function set_objectives_rhs_range(augmecon_model::AugmeconJuMP)
    solve_report = augmecon_model.report
    table = solve_report.table
    O = Base.OneTo(num_objectives(augmecon_model))
    maximum_o = [maximum(table[:, o]) for o in O]
    minimum_o = [minimum(table[:, o]) for o in O]
    return [range(minimum_o[o], maximum_o[o], length = ((maximum_o[o] - minimum_o[o]) != 0.0 ? augmecon_model.grid_points : 1)) for o in O]
end

function save_on_table!(table, i::Int64, augmecon_model::AugmeconJuMP)
    for o in Base.OneTo(num_objectives(augmecon_model))
        table[i, o] = lower_bound(augmecon_model.objectives_maximize[o])
    end
    return table
end

function optimize_and_fix!(augmecon_model::AugmeconJuMP, objective)
    model = augmecon_model.model
    @objective(model, Max, objective)
    optimize!(model)

    # Save report
    solve_report = augmecon_model.report
    solve_report.counter["table_solve_time"] += solve_time(model)
    # push!(solve_report.table_gap, relative_gap(model))

    set_lower_bound(objective, objective_value(model))
    return nothing
end

###############################
###############################

function set_model_for_augmecon!(augmecon_model::AugmeconJuMP, objectives_rhs, options)
    O = 2:num_objectives(augmecon_model)
    @variable(augmecon_model.model, 
        s[O] >= 0.0)
        
    if options[:bypass]
        @objective(augmecon_model.model, Max, augmecon_model.objectives_maximize[1] + 
            options[:penalty]*sum((objectives_rhs_range(objectives_rhs, o) > 0.0 ? (10.0^float(2-o)) * s[o]/objectives_rhs_range(objectives_rhs, o) : 0.0) for o in O))
            
    else
        @objective(augmecon_model.model, Max, augmecon_model.objectives_maximize[1] + 
            options[:penalty]*sum((objectives_rhs_range(objectives_rhs, o) > 0.0 ? s[o]/objectives_rhs_range(objectives_rhs, o) : 0.0) for o in O))
    end
    @constraint(augmecon_model.model, other_objectives[o in O], 
        augmecon_model.objectives_maximize[o] - s[o] == 0.0)
    return nothing
end

function objectives_rhs_range(objectives_rhs, o)
    return objectives_rhs[o][end] - objectives_rhs[o][1]
end

###############################
###############################

function recursive_augmecon2!(augmecon_model::AugmeconJuMP, frontier, objectives_rhs; o = num_objectives(augmecon_model), s_2)
    i_k = 0
    while i_k < augmecon_model.grid_points
        i_k += 1
        set_normalized_rhs(augmecon_model.model[:other_objectives][o], objectives_rhs[o][i_k])
        if o > 2
            recursive_augmecon2!(augmecon_model, frontier, objectives_rhs, o = o - 1, s_2 = s_2)
        else
            optimize_mo_method_model!(augmecon_model)
            if JuMP.has_values(augmecon_model.model)
                push!(frontier, SolutionJuMP(augmecon_model))
                b = get_number_of_redundant_iterations(s_2, objectives_rhs[o])
                i_k += b
            else
                i_k = augmecon_model.grid_points
            end
        end
    end
    return nothing
end

function recursive_augmecon!(augmecon_model::AugmeconJuMP, frontier, objectives_rhs; o = 2)
    for eps in objectives_rhs[o]
        set_normalized_rhs(augmecon_model.model[:other_objectives][o], eps)
        if o < num_objectives(augmecon_model)
            recursive_augmecon!(augmecon_model, frontier, objectives_rhs, o = o + 1)
        else
            optimize_mo_method_model!(augmecon_model)
            if JuMP.has_values(augmecon_model.model)
                push!(frontier, SolutionJuMP(augmecon_model))
            else
                break
            end
        end
    end
    return nothing
end

###############################
###############################

function convert_table_to_correct_sense!(augmecon_model::AugmeconJuMP)
    table = augmecon_model.report.table
    sense = augmecon_model.sense_value
    for i in axes(table, 1)
        for j in axes(table, 2)
            table[i, j] = table[i, j] * sense[j]
        end
    end
    return table
end


function optimize_mo_method_model!(augmecon_model::AugmeconJuMP)
    # start_time = tic()
    optimize!(augmecon_model.model)
    # stop_time = toc(start_time) # Some solvers doesn't work well with solve_time function
    augmecon_model.report.counter["solve_time"] += solve_time(augmecon_model.model)
    # println(solve_time(augmecon_model.model))
    augmecon_model.report.counter["iterations"] += 1.0
    # push!(augmecon_model.report.gap, relative_gap(augmecon_model.model))
    return augmecon_model
end

function get_number_of_redundant_iterations(s_2, objective_range)
    division = value(s_2)/objective_range.step.hi
    return since_solver_could_let_s_2_less_than_zero(division)
end

function since_solver_could_let_s_2_less_than_zero(b)
    result = trunc(Int64, b)
    return result
end

tic() = time()
toc(start_time) = time() - start_time 