local uv = vim.loop -- Alias for Neovim's event loop (libuv)

local PATH = vim.fn.stdpath("data") .. "/site/pack/paqs/"

local packages = {} -- Table of 'name':{plugin} pairs

local function print_res(action, args, ok)
    local res = ok and "Paq: " or "Paq: Failed to "
    print(res .. action .. " " .. args)
end

local call_cmd -- To handle mutual funtion recursion (Lua shenanigans)
local function run_hook(hook, name, dir)
    local t = type(hook)
    if t == "function" then
        vim.cmd("packloadall!")
        local ok = pcall(hook)
        print_res("run hook for", name, ok) -- FIXME: How to print an interned string?

    elseif t == "string" then
        local hook_cmd = {}
        for word in hook:gmatch("%S+") do
            table.insert(hook_cmd, word)
        end
        call_cmd(hook_cmd, name, dir, "run `"..hook.."` for")
    end
end

function call_cmd(cmd, name, dir, action, hook)
    local path, args = table.remove(cmd, 1), cmd
    local handle
    handle =
        uv.spawn(path,
            {args=args, cwd=(action ~= "install" and dir or nil)}, -- FIXME: Handle install case better
            vim.schedule_wrap(
                function(code)
                    print_res(action, name, code == 0)
                    if hook then run_hook(hook, name, dir) end
                    handle:close()
                end
            )
        )
end

local function install_pkg(name, dir, isdir, plugin)
    -- Plugin already installed
    if isdir then return end

    if plugin.type == "git" then
        local cmd
        if plugin.branch then
            cmd = {"git", "clone", plugin.url, "-b",  plugin.branch, "--single-branch", dir}
        else
            cmd = {"git", "clone", plugin.url, dir}
        end
        call_cmd(cmd, name, dir, "install", plugin.hook)

    elseif plugin.type == "local" then
        local cmd
        if vim.fn.executable("ln") then
            cmd = {"ln", "-sf", plugin.url, dir}
        elseif jit.os == "windows" then
            cmd = {"cmd", "/C", "mklink", "/d", plugin.url, dir}
        else
            print_res("install", "no executable symlink command found", false)
            return
        end
        call_cmd(cmd, name, dir, "install", plugin.hook)
    end
end

local function update_pkg(name, dir, isdir, plugin)
    -- Plugin already installed
    if not isdir then return end

    if plugin.type == "git" then
        call_cmd({"git", "pull"}, name, dir, "update", plugin.hook)
    elseif plugin.type == "local" then
        -- Local plugins are always up to date
    end
end

local function map_pkgs(fn)
    for name, plugin in pairs(packages) do
        local dir = PATH .. (plugin.opt and "opt/" or "start/") .. name
        local isdir = vim.fn.isdirectory(dir) ~= 0
        fn(name, dir, isdir, plugin)
    end
end

local function rmdir(dir, ispkgdir)
    local name, t, child, ok
    local handle = uv.fs_scandir(dir)
    while handle do
        name, t = uv.fs_scandir_next(handle)
        if not name then break end
        child = dir .. "/" .. name
        if ispkgdir then -- check which packages are listed
            if packages[name] then -- do nothing
                ok = true
            else -- package isn't listed, remove it
                ok = rmdir(child)
                print_res("uninstall", name, ok)
            end
        else -- it's an arbitrary directory or file
            ok = (t == "directory") and rmdir(child) or uv.fs_unlink(child)
        end
        if not ok then return end
    end
    return ispkgdir or uv.fs_rmdir(dir) -- Don't delete start or opt
end

local function paq(args)
    local path = type(args) == "string" and args or args[1]
    -- vim.fn.isdirectory doesn't recognize ~
    path = path:gsub("^~", os.getenv("HOME"))

    local plugin = {
        hook = args.hook,
        opt = args.opt,
        branch = args.branch,
    }
    if vim.fn.isdirectory(path) ~= 0 then
        plugin.name = args.as or path:match("^.+/(.+)$")
        plugin.type = "local"
        plugin.url = path
    elseif path:match("^[%w-]+/[%w-_.]+$") then
        plugin.name = args.as or path:match("^[%w-]+/([%w-_.]+)$")
        plugin.type = "git"
        plugin.url = "https://github.com/" .. path .. ".git"
    else
        plugin.name = args.as
        plugin.type = "git"
        plugin.url = path
    end

    if not plugin.name then
        print_res("parse", path)
        return
    end
    if plugin.branch ~= nil and plugin.type ~= "git" then
        print_res("parse", "`branch` only valid for git plugins")
        return
    end

    packages[plugin.name] = plugin
end

return {
    install = function() map_pkgs(install_pkg) end,
    update  = function() map_pkgs(update_pkg) end,
    clean   = function() rmdir(PATH.."start", true); rmdir(PATH.."opt", true) end,
    paq     = paq
}
