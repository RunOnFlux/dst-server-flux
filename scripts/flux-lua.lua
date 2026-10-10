-- Reads the game's Lua files as data, for fluxdst.py. Lua 5.1, the game's own version.
--
--   lua5.1 flux-lua.lua table   <file>                 the table the file returns, as JSON
--   lua5.1 flux-lua.lua modinfo <file> <folder_name>   a mod's modinfo.lua, as JSON
--
-- Both run the file in a SANDBOX: an environment with the harmless parts of the standard library
-- and nothing that reaches the disk, the network or the process (no io, os, require, load*,
-- dofile, debug). A Workshop author's modinfo.lua is someone else's code; it gets data in and
-- data out. A file that errors or loops (an instruction budget stops it) prints an error object
-- and exits 1.
--
-- The game writes some of these files with a "KLEI     1 " header in front of the Lua (measured:
-- worldgenoverride.lua after a save). It is dropped before loading.

local function json_string(s)
  s = s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return map[c] or string.format('\\u%04x', c:byte())
  end)
  return '"' .. s .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

local encode
encode = function(v, depth)
  depth = depth or 0
  if depth > 20 then return 'null' end
  local tv = type(v)
  if tv == 'nil' then return 'null'
  elseif tv == 'boolean' then return tostring(v)
  elseif tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.14g', v)
  elseif tv == 'string' then return json_string(v)
  elseif tv == 'table' then
    local arr, n = is_array(v)
    local out = {}
    if arr and n > 0 then
      for i = 1, n do out[#out + 1] = encode(v[i], depth + 1) end
      return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do
      if type(k) == 'string' or type(k) == 'number' then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local ev = v[k]
      if type(ev) ~= 'function' and type(ev) ~= 'userdata' and type(ev) ~= 'thread' then
        out[#out + 1] = json_string(tostring(k)) .. ':' .. encode(ev, depth + 1)
      end
    end
    return '{' .. table.concat(out, ',') .. '}'
  end
  return 'null'
end

local function fail(msg)
  io.write(encode({ error = tostring(msg) }), '\n')
  os.exit(1)
end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then fail('cannot open ' .. tostring(path)) end
  local s = f:read('*a')
  f:close()
  s = s:gsub('^\239\187\191', '')
  s = s:gsub('^KLEI%s+%d+%s', '')
  return s
end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local function sandbox()
  return {
    assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs,
    pcall = pcall, select = select, tonumber = tonumber, tostring = tostring, type = type,
    unpack = unpack, rawget = rawget, rawset = rawset, rawequal = rawequal,
    setmetatable = setmetatable, getmetatable = getmetatable,
    string = copy(string), table = copy(table), math = copy(math),
  }
end

-- Runs `src` in `env` with an instruction budget. Returns what the chunk returned.
local function run(src, name, env)
  local chunk, err = loadstring(src, '=' .. name)
  if not chunk then fail(err) end
  setfenv(chunk, env)
  local co = coroutine.create(chunk)
  debug.sethook(co, function() error('instruction budget exceeded', 2) end, '', 5000000)
  local ok, result = coroutine.resume(co)
  if not ok then fail(result) end
  return result
end

local mode, path = arg[1], arg[2]

if mode == 'table' then
  local result = run(read_file(path), path, sandbox())
  if type(result) ~= 'table' then fail('the file does not return a table') end
  io.write(encode(result), '\n')

elseif mode == 'modinfo' then
  -- What the game gives a modinfo.lua (ModIndex:InitializeModInfoEnv): the locale, the mod's
  -- folder name and ChooseTranslationTable. English, as the hub shows it.
  local env = sandbox()
  env.locale = 'en'
  env.folder_name = arg[3] or ''
  env.ChooseTranslationTable = function(tbl) return tbl and (tbl['en'] or tbl[1]) end
  run(read_file(path), path, env)
  local keep = {
    'name', 'description', 'author', 'version', 'api_version', 'api_version_dst',
    'dst_compatible', 'client_only_mod', 'all_clients_require_mod', 'server_only_mod',
    'forumthread', 'priority', 'server_filter_tags', 'configuration_options',
  }
  local out = {}
  for _, k in ipairs(keep) do out[k] = env[k] end
  io.write(encode(out), '\n')

else
  io.stderr:write('usage: flux-lua.lua table <file> | modinfo <file> <folder_name>\n')
  os.exit(64)
end
