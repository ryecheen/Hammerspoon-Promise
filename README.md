<center><h1>Promise in Hammerspoon</h1></center>

## _Constructor_
* `Promise(executor)`
  
* `Promise.new(executor)`

## _Static function_
* `Promise.resolve(any)`

* `Promise.reject(any)`

* `Promise.withResolvers()`

* `Promise.any(pairsIterable)`

* `Promise.race(pairsIterable)`

* `Promise.all(pairsIterable)`

* `Promise.allSettled(pairsIterable)`

* `Promise.isPromise(any)` : Return `true` if `any` is a promise.
```lua
---@param  any any
---@return boolean
```

* `Promise.sleep(sec)` : Wait `sec` seconds, then resolve. Default: 0
```lua
---@param  sec number|nil
---@return Promise
```

* `Promise.async(fn)` : Convert `fn` into an async function.
```lua
---@param  fn function
---@return Async function
```

* `Promise.await(any)` : Await `any` to be settled.
> [!IMPORTANT]  
> You can only use it within an async function.
```lua
---@param  any any
---@return any

local Promise = require("promise")

async1 = Promise.async(function()
    Promise.await(Promise.sleep(1))
    return "async1"
end)

async2 = Promise.async(function()
    local result = Promise.await(async1())
    print(result)
end)

async2()

-- (Wait for one second...)
-- Output: async1
```

* `Promise.fetch(url, options)` : A wrapper for `hs.http.doAsyncRequest`.
  &ensp;Options includes: 
  `headers`, `method`(Default "GET"), `body`, `cache`, and `redirect`.
  &ensp;Response includes:
  `url`, `reason`, `url`, `ok`, `status`, `body`, and `headers`.
> [!TIP]
> For possible values of `cache` and `redirect`, please refer to the
  [Hammerspoon documentation](https://www.hammerspoon.org/docs/hs.http.html#doAsyncRequest).

> [!NOTE]  
> The promise state does not depend on the HTTP status.
```lua
---@param  url string
---@param  options? table
---@return Promise settle with `Response`
```

* `Promise.fetchImg(url)` : A wrapper for `hs.image.imageFromURL`
```lua
---@param  url string
---@return Promise resolves with an `hs.image object` if successful.
```

## _Method_
* `Promise:next(onFulfilled, onRejected)`
* `Promise:catch(onRejected)`
* `Promise:finally(onFinally)`

## _Notice_
> [!WARNING]  
> All errors within a `Promise` or an `async function` will be absorbed by the 
> promise and will be reflected in its state. Therefore, it is strongly recommended to 
> chain an `onRejected` handler at the end, using either `next` or `catch`.

> [!NOTE]  
> If the promise settles with no value(`nil`), it will result in the 
> string `undefined`.
```lua
local Promise = require("promise")

Promise(function(res, rej) res() end)
    :next(function(val) print(val) end)

-- Output: undefined

Promise.async(function()
    local result1 = Promise.await(Promise.resolve())
    local result2 = Promise.await()
    print(result1, result2)
end)()

-- Output: undefined	undefined
```

## _Example_
```lua
local Promise = require("promise")

local posts = Promise.async(function()
    local url = "https://jsonplaceholder.typicode.com/posts/"
    local howmany = 5
    local pending = {}

    for i = 1, howmany do pending[i] = Promise.fetch(url .. i) end

    pending[#pending + 1] = Promise.reject("rejected by myself")

    -- Syntactic sugar for Promise.await
    -- Same as `Promise.await( Promise.allSettled(pending) )`
    local result = Promise.allSettled(pending)()

    for i = 1, #pending do
        print(
            string.format("%2s %-10s %s",
                i, result[i].status, result[i].value or result[i].reason
            )
        )
    end

    return result
end)()

posts
    :next(function(val)
        for i = 1, #val do
            if val[i].status == "fulfilled" then
                local response = val[i].value
                if response.ok then
                    local json = hs.json.decode(response.body)
                    print("title: ", json.title)
                end
            else
                error(val[i].reason)
            end
        end
    end)
    :catch(function(err) print("CATCH: ", err) end)
    :finally(function() print("FINALLY") end)
```


