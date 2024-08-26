---@class Promise
---@field next function
---@field catch function
---@field finally function

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --

local hs_doAfter        = hs.timer.doAfter
local hs_delayed        = hs.timer.delayed.new
local hs_doAsyncRequest = hs.http.doAsyncRequest
local hs_imageFromURL   = hs.image.imageFromURL

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --

local isCallable

function isCallable(any)
    if type(any) == "function" then return any end

    local mt = debug.getmetatable(any)

    if mt == nil then return nil end

    if type(mt.__call) == "function" then return any end

    return nil
end

---Simulate microtask.
local Microtask

Microtask           = {}
Microtask._queue    = {}
Microtask._executor = nil

function Microtask:enqueue(fn)
    if self._executor == nil then
        self._executor = hs_delayed(0, function()
            while #self._queue > 0 do table.remove(self._queue, 1)() end
        end)
    end

    self._queue[#self._queue + 1] = fn
    self._executor:start()
end

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --

local STATE_PENDING               = "pending"
local STATE_FULFILLED             = "fulfilled"
local STATE_REJECTED              = "rejected"
local RESULT_WHEN_SETTLE_WITH_NIL = "undefined"

local Promise
local execute

function execute(p)
    if p._state == STATE_PENDING then return end

    while #p._queue > 0 do
        local ele          = table.remove(p._queue, 1)
        local res, rej, cb = ele.res, ele.rej, ele[p._state]

        Microtask:enqueue(function()
            if not isCallable(cb) then
                local settle = p._state == STATE_FULFILLED and res or rej
                settle(p._result)
            else
                local _, result = xpcall(cb, rej, p._result)
                res(result)
            end
        end)
    end
end

Promise         = {}
Promise.__index = {}

---@param fn function
---@return Promise
function Promise.new(fn)
    local o = { _state = STATE_PENDING, _queue = {}, _result = nil }

    local function rej(e)
        if o._state ~= STATE_PENDING then return end
        if e == nil then e = RESULT_WHEN_SETTLE_WITH_NIL end
        o._state, o._result = STATE_REJECTED, e
        execute(o)
    end

    local function res(v)
        if o._state ~= STATE_PENDING then return end
        if v == o then
            rej("Chaining cycle detected for promise")
        elseif getmetatable(v) == Promise then
            -- promiseResolveThenableJob
            -- https://tc39.es/ecma262/#sec-newpromiseresolvethenablejob
            Microtask:enqueue(function() v:next(res, rej) end)
        else
            if v == nil then v = RESULT_WHEN_SETTLE_WITH_NIL end
            o._state, o._result = STATE_FULFILLED, v
            execute(o)
        end
    end

    xpcall(fn, rej, res, rej)

    return setmetatable(o, Promise)
end

---@param val any
---@return Promise
function Promise.resolve(val)
    if getmetatable(val) == Promise then return val end
    return Promise(function(res, rej) res(val) end)
end

---@param err any
---@return Promise
function Promise.reject(err)
    return Promise(function(res, rej) rej(err) end)
end

---@return Promise
---@return function
---@return function
function Promise.withResolvers()
    local resolve, reject
    local promise = Promise(function(res, rej) resolve, reject = res, rej end)
    return promise, resolve, reject
end

---@param pairsIterable table|any[]
---@return Promise
function Promise.any(pairsIterable)
    local pro, res, rej = Promise.withResolvers()
    local result        = {}
    local pending       = 0

    for k, v in pairs(pairsIterable) do
        pending = pending + 1
        Promise.resolve(v)
            :next(
                res,
                function(err)
                    result[k] = err
                    pending = pending - 1
                    if pending == 0 then rej(result) end
                end
            )
    end

    if pending == 0 then rej(result) end

    return pro
end

---@param pairsIterable table|any[]
---@return Promise
function Promise.race(pairsIterable)
    local pro, res, rej = Promise.withResolvers()

    for k, v in pairs(pairsIterable) do Promise.resolve(v):next(res, rej) end

    return pro
end

---@param pairsIterable table|any[]
---@return Promise
function Promise.all(pairsIterable)
    local pro, res, rej = Promise.withResolvers()
    local result        = {}
    local pending       = 0

    for k, v in pairs(pairsIterable) do
        pending = pending + 1
        Promise.resolve(v)
            :next(
                function(val)
                    result[k] = val
                    pending = pending - 1
                    if pending == 0 then res(result) end
                end,
                rej
            )
    end

    if pending == 0 then res(result) end

    return pro
end

---@param pairsIterable table|any[]
---@return Promise
function Promise.allSettled(pairsIterable)
    local pro, res, rej = Promise.withResolvers()
    local result        = {}
    local pending       = 0

    for k, v in pairs(pairsIterable) do
        pending = pending + 1
        Promise.resolve(v)
            :next(
                function(val)
                    result[k] = { status = STATE_FULFILLED, value = val }
                end,
                function(err)
                    result[k] = { status = STATE_REJECTED, reason = err }
                end
            )
            :finally(function()
                pending = pending - 1
                if pending == 0 then res(result) end
            end)
    end

    if pending == 0 then res(result) end

    return pro
end

---@param any any
---@return boolean
function Promise.isPromise(any) return getmetatable(any) == Promise end

---@param sec number? #Default 0
---@return Promise
function Promise.sleep(sec)
    sec = sec or 0
    return Promise(function(res) hs_doAfter(sec, res) end)
end

---@param fn function
---@return function #Async function
function Promise.async(fn)
    return function(...)
        local co                       = coroutine.create(fn)
        local promise, resolve, reject = Promise.withResolvers()

        local function resume(...)
            local ok, fromYield = coroutine.resume(co, ...)

            if not ok then
                reject(fromYield)
                return
            end

            if coroutine.status(co) == "dead" then
                resolve(fromYield)
                return
            end

            Promise.resolve(fromYield)
                :next(function(val) resume(STATE_FULFILLED, val) end,
                    function(err) resume(STATE_REJECTED, err) end)
        end

        resume(...)

        return promise
    end
end

---@param any any
---@return any
function Promise.await(any)
    local promiseState, promiseResult = coroutine.yield(any)
    if promiseState == STATE_REJECTED then
        error(promiseResult, 2)
    else
        return promiseResult
    end
end

---@param url string
---@param options? table
---@return Promise #Promise settle with `Response`.
function Promise.fetch(url, options)
    options        = options or {}
    local headers  = options.headers
    local method   = options.method or "GET"
    local body     = options.body
    local cache    = options.cache
    local redirect = options.redirect

    if cache == nil then cache = "protocolCachePolicy" end
    if redirect == nil then redirect = true end

    local pro, res, rej = Promise.withResolvers()

    hs_doAsyncRequest(url, method, body, headers, function(http, b, h)
        local response = { url = url }
        if http < 0 then
            response.reason = b
            rej(response)
        else
            response.ok      = http > 199 and http < 300
            response.status  = http
            response.body    = b
            response.headers = h
            res(response)
        end
    end, cache, redirect)

    return pro
end

---@param url string
---@return Promise #Promise resolves with an `hs.image object` if successful.
function Promise.fetchImg(url)
    local pro, res, rej = Promise.withResolvers()

    hs_imageFromURL(url, function(img) (img == nil and rej or res)(img) end)

    return pro
end

---@return any #promise result.
---@return string? #promise state.
function Promise:__call()
    local _, ismain = coroutine.running()

    if ismain then
        return self._result, self._state
    else
        return Promise.await(self)
    end
end

function Promise:__tostring()
    if self._state == STATE_PENDING then
        return ("Promise <%s>"):format(self._state)
    else
        if type(self._result) == "string" then
            return ("Promise <%s> -- \"%s\""):format(self._state, self._result)
        else
            return ("Promise <%s> -- %s"):format(self._state, self._result)
        end
    end
end

---@param onFulfilled any
---@param onRejected any
---@return Promise
function Promise.__index:next(onFulfilled, onRejected)
    assert(getmetatable(self) == Promise, "New an instance before call.")
    return Promise(function(res, rej)
        self._queue[#self._queue + 1] = {
            res               = res,
            rej               = rej,
            [STATE_FULFILLED] = onFulfilled,
            [STATE_REJECTED]  = onRejected
        }
        execute(self)
    end)
end

---@param onRejected any
---@return Promise
function Promise.__index:catch(onRejected)
    assert(getmetatable(self) == Promise, "New an instance before call.")
    return self:next(nil, onRejected)
end

---@param onFinally any
---@return Promise
function Promise.__index:finally(onFinally)
    assert(getmetatable(self) == Promise, "New an instance before call.")
    local function run(settle, result)
        settle(result)
        if isCallable(onFinally) then onFinally() end
    end
    return Promise(function(res, rej)
        self:next(
            function(val) run(res, val) end,
            function(err) run(rej, err) end
        )
    end)
end

return setmetatable(Promise, {
    __call = function(self, ...) return self.new(...) end
})
