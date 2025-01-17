# This file is a part of Julia. License is MIT: http://julialang.org/license


"""
    AsyncCollector(f, results, c...; ntasks=100) -> iterator

Apply f to each element of c using at most 100 asynchronous tasks.
For multiple collection arguments, apply f elementwise.
Output is collected into "results".

Note: `next(::AsyncCollector, state) -> (nothing, state)`

Note: `for task in AsyncCollector(f, results, c...) end` is equivalent to
`map!(f, results, c...)`.
"""
type AsyncCollector
    f
    results
    enumerator::Enumerate
    ntasks::Int
end

function AsyncCollector(f, results, c...; ntasks=0)
    if ntasks == 0
        ntasks = 100
    end
    AsyncCollector(f, results, enumerate(zip(c...)), ntasks)
end


type AsyncCollectorState
    enum_state
    active_count::Int
    task_done::Condition
    done::Bool
end


# Busy if the maximum number of concurrent tasks is running.
function isbusy(itr::AsyncCollector, state::AsyncCollectorState)
    state.active_count == itr.ntasks
end


# Wait for @async task to end.
wait(state::AsyncCollectorState) = wait(state.task_done)


# Open a @sync block and initialise iterator state.
function start(itr::AsyncCollector)
    sync_begin()
    AsyncCollectorState(start(itr.enumerator),  0, Condition(), false)
end

# Close @sync block when iterator is done.
function done(itr::AsyncCollector, state::AsyncCollectorState)
    if !state.done && done(itr.enumerator, state.enum_state)
        state.done = true
        sync_end()
    end
    return state.done
end

function next(itr::AsyncCollector, state::AsyncCollectorState)

    # Wait if the maximum number of concurrent tasks are already running...
    while isbusy(itr, state)
        wait(state)
    end

    # Get index and mapped function arguments from enumeration iterator...
    (i, args), state.enum_state = next(itr.enumerator, state.enum_state)

    # Execute function call and save result asynchronously...
    @async begin
        itr.results[i] = itr.f(args...)
        state.active_count -= 1
        notify(state.task_done, nothing)
    end

    # Count number of concurrent tasks...
    state.active_count += 1

    return (nothing, state)
end



"""
    AsyncGenerator(f, c...; ntasks=100) -> iterator

Apply f to each element of c using at most 100 asynchronous tasks.
For multiple collection arguments, apply f elementwise.
Results are returned by the iterator as they become available.
Note: `collect(AsyncGenerator(f, c...; ntasks=1))` is equivalent to
`map(f, c...)`.
"""
type AsyncGenerator
    collector::AsyncCollector
end

function AsyncGenerator(f, c...; ntasks=0)
    AsyncGenerator(AsyncCollector(f, Dict{Int,Any}(), c...; ntasks=ntasks))
end


type AsyncGeneratorState
    i::Int
    async_state::AsyncCollectorState
end


start(itr::AsyncGenerator) = AsyncGeneratorState(0, start(itr.collector))

# Done when source async collector is done and all results have been consumed.
function done(itr::AsyncGenerator, state::AsyncGeneratorState)
    done(itr.collector, state.async_state) && isempty(itr.collector.results)
end

# Pump the source async collector if it is not already busy...
function pump_source(itr::AsyncGenerator, state::AsyncGeneratorState)
    if !isbusy(itr.collector, state.async_state) &&
       !done(itr.collector, state.async_state)
        ignored, state.async_state = next(itr.collector, state.async_state)
        return true
    else
        return false
    end
end

function next(itr::AsyncGenerator, state::AsyncGeneratorState)

    state.i += 1

    results = itr.collector.results
    while !haskey(results, state.i)

        # Wait for results to become available...
        if !pump_source(itr,state) && !haskey(results, state.i)
            wait(state.async_state)
        end
    end
    r = results[state.i]
    delete!(results, state.i)

    return (r, state)
end

iteratorsize(::Type{AsyncGenerator}) = SizeUnknown()


"""
    asyncgenerate(f, c...) -> iterator

Apply `@async f` to each element of `c`.

For multiple collection arguments, apply f elementwise.

Results are returned in order as they become available.
"""
asyncgenerate(f, c...) = AsyncGenerator(f, c...)


"""
    asyncmap(f, c...) -> collection

Transform collection `c` by applying `@async f` to each element.

For multiple collection arguments, apply f elementwise.
"""
asyncmap(f, c...) = collect(asyncgenerate(f, c...))


"""
    asyncmap!(f, c)

In-place version of `asyncmap()`.
"""
asyncmap!(f, c) = (for x in AsyncCollector(f, c, c) end; c)


"""
    asyncmap!(f, results, c...)

Like `asyncmap()`, but stores output in `results` rather returning a collection.
"""
asyncmap!(f, r, c1, c...) = (for x in AsyncCollector(f, r, c1, c...) end; r)
