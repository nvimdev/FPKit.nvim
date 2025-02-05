-- F.lua: Functional Programming Utilities
local F = {}

-- Core FP utilities
F.curry = function(fn)
  local function curry_n(n, fn)
    if n <= 1 then
      return fn
    end
    return function(x)
      return curry_n(n - 1, function(...)
        return fn(x, ...)
      end)
    end
  end
  return curry_n(debug.getinfo(fn).nparams, fn)
end

F.compose = function(...)
  local fns = { ... }
  return function(...)
    local result = ...
    for i = #fns, 1, -1 do
      result = fns[i](result)
    end
    return result
  end
end

F.pipe = function(x, ...)
  local fns = { ... }
  local result = x
  for i = 1, #fns do
    result = fns[i](result)
  end
  return result
end

-- Maybe Monad
F.Maybe = {
  of = function(x)
    return { kind = 'Maybe', value = x }
  end,
  nothing = { kind = 'Maybe', value = nil },
  isNothing = function(maybe)
    return maybe.value == nil
  end,
  fromNullable = function(x)
    return x == nil and F.Maybe.nothing or F.Maybe.of(x)
  end,
  map = function(maybe, f)
    if F.Maybe.isNothing(maybe) then
      return F.Maybe.nothing
    end
    return F.Maybe.of(f(maybe.value))
  end,
  chain = function(maybe, f)
    if F.Maybe.isNothing(maybe) then
      return F.Maybe.nothing
    end
    return f(maybe.value)
  end,
  getOrElse = function(maybe, default)
    return maybe.value or default
  end,
}

-- Either Monad
F.Either = {
  Left = function(x)
    return { kind = 'Either', tag = 'Left', value = x }
  end,
  Right = function(x)
    return { kind = 'Either', tag = 'Right', value = x }
  end,
  map = function(e, f)
    if e.tag == 'Left' then
      return e
    end
    return F.Either.Right(f(e.value))
  end,
  chain = function(e, f)
    if e.tag == 'Left' then
      return e
    end
    return f(e.value)
  end,
  catch = function(e, f)
    if e.tag == 'Right' then
      return e
    end
    return f(e.value)
  end,
}

-- IO Monad
F.IO = {
  of = function(x)
    return {
      kind = 'IO',
      run = function()
        return F.Either.Right(x)
      end,
    }
  end,
  fail = function(error)
    return {
      kind = 'IO',
      run = function()
        return F.Either.Left(error)
      end,
    }
  end,
  fromEffect = function(effect)
    return {
      kind = 'IO',
      run = function()
        local ok, result = pcall(effect)
        return F.Either[ok and 'Right' or 'Left'](result)
      end,
    }
  end,
  map = function(io, f)
    return {
      kind = 'IO',
      run = function()
        local result = io.run()
        return F.Either.map(result, f)
      end,
    }
  end,
  chain = function(io, f)
    return {
      kind = 'IO',
      run = function()
        local result = io.run()
        return F.Either.chain(result, function(x)
          local next_io = f(x)
          return next_io.run()
        end)
      end,
    }
  end,
  catchError = function(io, handler)
    return {
      kind = 'IO',
      run = function()
        local result = io.run()
        if result.tag == 'Left' then
          return handler(result.value).run()
        end
        return result
      end,
    }
  end,
}

-- Lens implementation
F.Lens = {
  make = function(getter, setter)
    return {
      get = getter,
      set = setter,
      modify = function(f)
        return function(s)
          return setter(s, f(getter(s)))
        end
      end,
    }
  end,
}

return F
