local task = {};

--[[
    Cancels a task.

    @param thread The task to cancel.
]]
task.cancel = (nil :: any) :: (thread : thread) -> ();

--[[
    Defers a task.

    Runs on next frame.

    @param f The function to defer.
    @return thread
]]
task.defer = (nil :: any) :: <A..., R...>(f: ((A...) -> R...) | thread, A...) -> thread;

--[[
    Delays a task.

    Runs after a certain amount of time.

    @param sec The time to delay.
    @param f The function to delay.
    @return thread
]]
task.delay = (nil :: any) :: <A..., R...>(sec: number, f: ((A...) -> (R...)) | thread, A...) -> thread

--[[
    Spawns a task.

    Runs immediately.

    @param f The function to spawn.
    @return thread
]]
task.spawn = (nil :: any) :: <A..., R...>(f: ((A...) -> (R...)) | thread, A...) -> thread

--[[
    Sleeps task.

    Yields caller.
    Resumes after a certain amount of time.

    @param sec The time to wait.
    @return number
]]
task.wait = (nil :: any) :: (sec: number?) -> number

--[[
    Counts the number of tasks.

    Optional kinds parameter to count a specific kind of task.

    Kinds:
    - `s` to count sleeping tasks.
    - `d` to count deferred tasks.
    - `w` to count awaiting tasks. (Zune backend)
    - `t` to count internal tasks. (Zune backend)

    #### Example

    ```luau
    task.defer(function() end)
    task.spawn(function() task.wait(1) end)
    print(task.count("sd")) -- 2
    print(task.count("d")) -- 1
    print(task.count()) -- 2
    ```

    @param kinds The kinds of tasks to count.
    @return number
]]
task.count = (nil :: any) :: (() -> number) & ((kinds: string?) -> ...number)

return task;
