local api, uv, ffi, Iter = vim.api, vim.uv, require('ffi'), vim.iter
local FileOps = require('fpkit.FileOps')
local ns_id = api.nvim_create_namespace('dired_highlights')
local F = require('fpkit.F')
local ns_cur = api.nvim_create_namespace('dired_cursor')
local SEPARATOR = vim.uv.os_uname().sysname:match('win') and '/' or '\\'

-- FFI definitions
ffi.cdef([[
typedef unsigned int uv_uid_t;
int os_get_uname(uv_uid_t uid, char *s, size_t len);
]])

---@class KeyMapConfig
---@field open string|table<string, string>
---@field up string|table<string, string>
---@field delete string|table<string, string>
---@field quit string|table<string, string>
---@field create_file string|table<string, string>
---@field create_dir string|table<string, string>
---@field rename string|table<string, string>
---@field copy string|table<string, string>
---@field paste string|table<string, string>
---@field cut string|table<string, string>
---@field toogle_hidden string|table<string, string>
---@field forward string|table<string, string>
---@field backward string|table<string, string>

---@class DiredConfig
---@field show_hidden boolean
---@field prompt_start_insert boolean
---@field prompt_insert_on_open boolean
---@field keymaps KeyMapConfig

---@type DiredConfig
local Config = setmetatable({}, {
  __index = function(_, scope)
    local default = {
      show_hidden = true,
      prompt_start_insert = true,
      prompt_insert_on_open = true,
      keymaps = {
        open = { i = '<CR>', n = '<CR>' },
        up = 'u',
        quit = { n = 'q', i = '<C-c>' },
        create_file = { n = 'cf', i = '<C-f>' },
        create_dir = { n = 'cd', i = '<C-d>' },
        delete = 'D',
        rename = { n = 'R', i = '<C-r>' },
        copy = 'yy',
        cut = 'dd',
        paste = 'p',
        forward = { i = '<C-n>', n = 'j' },
        backward = { i = '<C-p>', n = 'k' },
      },
    }
    if vim.g.dired and vim.g.dired[scope] ~= nil then
      return vim.g.dired[scope]
    end
    return default[scope]
  end,
})

-- Pure formatting utilities
local Format = {}

Format.permissions = function(mode)
  local bit = require('bit')
  local function formatSection(r, w, x)
    return table.concat({
      bit.band(mode, r) ~= 0 and 'r' or '-',
      bit.band(mode, w) ~= 0 and 'w' or '-',
      bit.band(mode, x) ~= 0 and 'x' or '-',
    })
  end

  return table.concat({
    formatSection(0x100, 0x080, 0x040),
    formatSection(0x020, 0x010, 0x008),
    formatSection(0x004, 0x002, 0x001),
  })
end

Format.username = function(user_id)
  local name_out = ffi.new('char[100]')
  ffi.C.os_get_uname(user_id, name_out, 100)
  return ffi.string(name_out)
end

Format.size = function(size)
  local units = {
    { limit = 1024 * 1024 * 1024, unit = 'G' },
    { limit = 1024 * 1024, unit = 'M' },
    { limit = 1024, unit = 'K' },
    { limit = 0, unit = 'B' },
  }

  for _, unit in ipairs(units) do
    if size > unit.limit then
      local converted = unit.limit > 0 and size / unit.limit or size
      return string.format('%.2f%s', converted, unit.unit)
    end
  end
  return string.format('%.2f%s', size, 'B')
end

-- UI Components
local UI = {}

UI.Highlights = {
  set_header_highlights = function(bufnr)
    api.nvim_buf_set_extmark(bufnr, ns_id, 0, 0, {
      line_hl_group = 'DiredHeader',
      end_row = 0,
    })
    api.nvim_buf_set_extmark(bufnr, ns_id, 1, 0, {
      line_hl_group = 'DiredHeaderLine',
      end_row = 1,
    })
  end,

  set_entry_highlights = function(bufnr, line_num, entry)
    local line = api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]
    if not line then
      return
    end

    local line_length = vim.fn.strchars(line)

    local function safe_highlight(start_col, end_col, hl_group)
      if start_col >= line_length then
        return
      end
      end_col = math.min(end_col, line_length)

      api.nvim_buf_set_extmark(bufnr, ns_id, line_num, start_col, {
        hl_group = hl_group,
        end_col = end_col,
      })
    end

    -- permissions (0-10)
    safe_highlight(0, 10, 'DiredPermissions')

    -- user (11-20)
    safe_highlight(11, 20, 'DiredUser')

    -- size (21-30)
    safe_highlight(21, 30, 'DiredSize')

    -- date (31-50)
    safe_highlight(31, 50, 'DiredDate')

    -- filename
    local name_start = 55
    local name_length = #entry.name + (entry.stat.type == 'directory' and 1 or 0)
    local hl_group = 'NormalFloat'

    if entry.stat.type == 'directory' then
      hl_group = 'DiredDirectory'
    elseif entry.stat.type == 'link' then
      hl_group = 'DiredSymlink'
    elseif entry.stat.type == 'file' then
      hl_group = 'DiredFile'
    elseif bit.band(entry.stat.mode, 0x00040) ~= 0 then
      hl_group = 'DiredExecutable'
    end

    safe_highlight(name_start, name_start + name_length, hl_group)
  end,
}

UI.Entry = {
  render = function(entry)
    local formatted = {
      perms = Format.permissions(entry.stat.mode),
      user = Format.username(entry.stat.uid),
      size = Format.size(entry.stat.size),
      time = os.date('%Y-%m-%d %H:%M', entry.stat.mtime.sec),
      name = entry.name .. (entry.stat.type == 'directory' and SEPARATOR or ''),
    }

    return string.format(
      '%-11s %-10s %-10s %-20s %s',
      formatted.perms,
      formatted.user,
      formatted.size,
      formatted.time,
      formatted.name
    )
  end,
}

UI.Window = {
  create = function(config)
    return F.IO.fromEffect(function()
      -- Create search window
      local search_buf = api.nvim_create_buf(false, false)
      local search_win = api.nvim_open_win(search_buf, true, {
        relative = 'editor',
        width = config.width,
        height = 1,
        row = config.row - 2,
        border = {
          { '╭' },
          { '─' },
          { '╮' },
          { '│' },
          { '╯' },
          { '' },
          { '╰' },
          { '│' },
        },
        col = config.col,
        hide = true,
        style = 'minimal',
      })

      -- Setup search buffer properties
      vim.bo[search_buf].buftype = 'prompt'
      vim.bo[search_buf].bufhidden = 'wipe'
      vim.wo[search_win].wrap = false

      -- Create main window
      local buf = api.nvim_create_buf(false, false)
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = config.width,
        height = config.height,
        row = config.row,
        col = config.col,
        border = {
          { '│' },
          { ' ', 'NormalFloat' },
          { '│' },
          { '│' },
          { '╯' },
          { '─' },
          { '╰' },
          { '│' },
        },
        hide = true,
      })

      -- Setup main buffer properties
      vim.bo[buf].buftype = 'nofile'
      vim.bo[buf].bufhidden = 'wipe'
      vim.wo[win].wrap = false
      vim.wo[win].number = false
      vim.wo[win].stc = ''
      vim.wo[win].fillchars = 'eob: '

      -- Enter insert mode in prompt buffer
      vim.cmd.startinsert()
      vim.schedule(function()
        if not Config.prompt_start_insert then
          api.nvim_feedkeys(api.nvim_replace_termcodes('<ESC>', true, false, true), 'n', false)
        end
      end)

      return {
        search_buf = search_buf,
        search_win = search_win,
        buf = buf,
        win = win,
      }
    end)
  end,

  setup = function(state)
    return F.IO.fromEffect(function()
      vim.bo[state.buf].modifiable = true
      local header = string.format(
        '%-11s %-10s %-10s %-20s %s',
        'Permissions',
        'Owner',
        'Size',
        'Last Modified',
        'Name'
      )

      api.nvim_buf_set_lines(state.buf, 0, -1, false, {
        header,
        string.rep('-', #header),
      })

      return state
    end)
  end,
}

-- Browser implementation
local Browser = {}

Browser.State = {
  lens = {
    path = F.Lens.make(function(s)
      return s.current_path
    end, function(s, v)
      return vim.tbl_extend('force', s, { current_path = v })
    end),
    entries = F.Lens.make(function(s)
      return s.entries
    end, function(s, v)
      return vim.tbl_extend('force', s, { entries = v })
    end),
  },

  -- Added back the create function
  create = function(path)
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    local dimensions = {
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
    }

    return F.IO.chain(UI.Window.create(dimensions), function(state)
      return F.IO.chain(UI.Window.setup(state), function(s)
        s.current_path = path
        s.entries = {}
        s.show_hidden = Config.show_hidden

        -- Function to update display with entries
        local function update_display(s, entries_to_show)
          vim.bo[s.buf].modifiable = true

          local header = api.nvim_buf_get_lines(s.buf, 0, 2, false)
          api.nvim_buf_set_lines(s.buf, 0, -1, false, header)

          for _, entry in ipairs(entries_to_show) do
            local line = UI.Entry.render(entry)
            api.nvim_buf_set_lines(s.buf, -1, -1, false, { line })
          end

          vim.bo[s.buf].modifiable = false

          vim.schedule(function()
            UI.Highlights.set_header_highlights(s.buf)
            for i, entry in ipairs(entries_to_show) do
              UI.Highlights.set_entry_highlights(s.buf, i + 1, entry)
            end

            if #entries_to_show > 0 then
              api.nvim_win_set_cursor(state.win, { 3, 1 })
              Browser.update_current_hl(state, 2)
            end
          end)
        end

        local timer = assert(vim.uv.new_timer())
        -- Attach buffer for search
        api.nvim_buf_attach(s.search_buf, false, {
          on_lines = function()
            -- Get search text without prompt path
            local text =
              api.nvim_get_current_line():gsub(s.current_path, ''):gsub('^' .. SEPARATOR, '')

            -- Clear previous timer if exists
            if timer:is_active() then
              timer:stop()
            end

            -- Set new timer for delayed search
            timer:start(
              200,
              0,
              vim.schedule_wrap(function()
                if text:match(SEPARATOR .. '$') then
                  return
                end
                if text and #text > 0 then
                  local filtered_entries = {}
                  for _, entry in ipairs(s.entries) do
                    if entry.name:lower():find(text:lower()) then
                      table.insert(filtered_entries, entry)
                    end
                  end
                  update_display(s, filtered_entries)
                else
                  Browser.refresh(s, s.current_path).run()
                end
              end)
            )
          end,
          on_detach = function()
            -- Clean up timer when buffer is closed
            if timer:is_active() then
              timer:stop()
            end
            timer:close()
          end,
        })

        return F.IO.of(s)
      end)
    end)
  end,
}

local function notify_wrapper(level)
  return function(msg)
    vim.schedule(function()
      vim.notify(msg, level)
    end)
  end
end

local Notify = {}

Notify.err = notify_wrapper(vim.log.levels.ERROR)
Notify.info = notify_wrapper(vim.log.levels.INFO)

-- Enhanced Browser operations using async file operations
Browser.Operations = {
  -- Create new file
  createFile = function(state, name, content)
    local path = vim.fs.joinpath(state.current_path, name)
    return F.IO.fromEffect(function()
      FileOps.createFile(path, content).fork(function(err)
        Notify.err(err)
      end, function()
        Notify.info('Created file: ' .. name)
        Browser.refresh(state, state.current_path).run()
      end)
      return state
    end)
  end,

  -- Create new directory
  createDirectory = function(state, name)
    local path = vim.fs.joinpath(state.current_path, name)
    return F.IO.fromEffect(function()
      FileOps.createDirectory(path).fork(function(err)
        Notify.err(err)
      end, function()
        Notify.info('Created directory: ' .. name)
        Browser.refresh(state, state.current_path).run()
      end)
      return state
    end)
  end,

  -- Delete file or directory
  delete = function(state, name)
    local path = vim.fs.joinpath(state.current_path, name)
    return F.IO.fromEffect(function()
      uv.fs_stat(path, function(err, stat)
        if err or not stat then
          Notify.err('Failed to stat path: ' .. err)
          return
        end

        local op = stat.type == 'directory' and FileOps.deleteDirectory or FileOps.deleteFile
        ---@diagnostic disable-next-line: redefined-local
        op(path).fork(function(err)
          Notify.err(err)
        end, function()
          Notify.info('Deleted: ' .. name)
          Browser.refresh(state, state.current_path).run()
        end)
      end)
      return state
    end)
  end,

  -- Copy file or directory
  copy = function(state, src_name, dest_name)
    local src = vim.fs.joinpath(state.current_path, src_name)
    local dest = vim.fs.joinpath(state.current_path, dest_name)
    return F.IO.fromEffect(function()
      FileOps.copy(src, dest).fork(function(err)
        Notify.err(err)
      end, function()
        Notify.info('Copied: ' .. src_name .. ' to ' .. dest_name)
        Browser.refresh(state, state.current_path).run()
      end)
      return state
    end)
  end,

  -- Move/rename file or directory
  move = function(state, old_name, new_name)
    local src = vim.fs.joinpath(state.current_path, old_name)
    local dest = vim.fs.joinpath(state.current_path, new_name)
    return F.IO.fromEffect(function()
      FileOps.move(src, dest).fork(function(err)
        Notify.err(err)
      end, function()
        Notify.info('Moved: ' .. old_name .. ' to ' .. new_name)
        Browser.refresh(state, state.current_path).run()
      end)
      return state
    end)
  end,

  -- Add cut-move operation
  cutMove = function(state, src_name, dest_name)
    local src = vim.fs.joinpath(state.current_path, src_name)
    local dest = vim.fs.joinpath(state.current_path, dest_name)
    return F.IO.fromEffect(function()
      FileOps.move(src, dest).fork(function(err)
        Notify.err(err)
      end, function()
        Notify.info('Moved: ' .. src_name .. ' to ' .. dest_name)
        -- Clear clipboard after successful move
        state.clipboard = nil
        state.clipboard_type = nil
        Browser.refresh(state, state.current_path).run()
      end)
      return state
    end)
  end,

  -- Preview file content if we need
  preview = function(state, name)
    local path = vim.fs.joinpath(state.current_path, name)
    return F.IO.fromEffect(function()
      FileOps.readFile(path, 1024).fork(function(err)
        Notify.err(err)
      end, function(content)
        local lines = vim.split(content, '\n')
        vim.schedule(function()
          local bufnr = api.nvim_create_buf(false, false)
          api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          local cfg = api.nvim_win_get_config(0)
          api.nvim_open_win(bufnr, false, {
            relative = 'editor',
            width = cfg.width,
            height = math.min(#lines, cfg.row),
            row = 1,
            col = cfg.col,
            style = 'minimal',
            border = 'rounded',
          })
        end)
      end)
      return state
    end)
  end,
}

Browser.update_current_hl = function(state, row)
  api.nvim_buf_clear_namespace(state.buf, ns_cur, 0, -1)
  api.nvim_buf_set_extmark(state.buf, ns_cur, row, 0, {
    line_hl_group = 'DiredCurrent',
    hl_mode = 'combine',
  })
end

Browser.setup = function(state)
  return F.IO.fromEffect(function()
    local keymaps = {
      {
        key = Config.keymaps.open,
        action = function()
          local line = api.nvim_get_current_line()
          local name = line:match('%s(%S+)$')
          local current = state.current_path
          local new_path = vim.fs.joinpath(current, name)
          local mode = api.nvim_get_mode().mode

          if vim.fn.isdirectory(new_path) == 1 then
            Browser.refresh(state, new_path).run()
            state.current_path = new_path
            if mode ~= 'i' and Config.prompt_insert_on_open then
              vim.cmd.startinsert()
            end
          else
            api.nvim_win_close(state.win, true)
            api.nvim_win_close(state.search_win, true)
            vim.cmd.stopinsert()
            vim.cmd.edit(new_path)
          end
        end,
      },
      {
        key = Config.keymaps.up,
        action = function()
          local current = state.current_path
          local parent = vim.fs.dirname(vim.fs.normalize(current))
          Browser.refresh(state, parent).run()
          state.current_path = parent
        end,
      },
      {
        key = Config.keymaps.quit,
        action = function()
          api.nvim_win_close(state.win, true)
          api.nvim_win_close(state.search_win, true)
          vim.cmd.stopinsert()
        end,
      },
      {
        key = Config.keymaps.create_file,
        action = function()
          vim.ui.input({ prompt = 'Create file: ' }, function(name)
            if name then
              Browser.Operations.createFile(state, name).run()
            end
          end)
        end,
      },
      {
        key = Config.keymaps.create_dir,
        action = function()
          vim.ui.input({ prompt = 'Create directory: ' }, function(name)
            if name then
              Browser.Operations.createDirectory(state, name).run()
            end
          end)
        end,
      },
      {
        key = Config.keymaps.delete,
        action = function()
          local line = api.nvim_get_current_line()
          local name = line:match('%s(%S+)$')
          if name then
            vim.ui.input({
              prompt = string.format('Delete %s? (y/n): ', name),
            }, function(input)
              if input and input:lower() == 'y' then
                Browser.Operations.delete(state, name).run()
              end
            end)
          end
        end,
      },
      {
        key = Config.keymaps.rename,
        action = function()
          local line = api.nvim_get_current_line()
          local old_name = line:match('%s(%S+)$')
          if old_name then
            vim.ui.input({
              prompt = string.format('Rename %s to: ', old_name),
            }, function(new_name)
              if new_name then
                Browser.Operations.move(state, old_name, new_name).run()
              end
            end)
          end
        end,
      },
      {
        key = Config.keymaps.copy,
        action = function()
          local line = api.nvim_get_current_line()
          local name = line:match('%s(%S+)$')
          if name then
            state.clipboard = name
            vim.notify('Yanked: ' .. name)
          end
        end,
      },
      -- Add cut operation
      {
        key = Config.keymaps.cut,
        action = function()
          local line = api.nvim_get_current_line()
          local name = line:match('%s(%S+)$')
          if name then
            state.clipboard = name
            state.clipboard_type = 'cut' -- Mark as cut operation
            vim.notify('Cut: ' .. name)
          end
        end,
      },
      {
        key = Config.keymaps.paste,
        action = function()
          if state.clipboard then
            local operation = state.clipboard_type == 'cut' and Browser.Operations.cutMove
              or Browser.Operations.copy
            local action_name = state.clipboard_type == 'cut' and 'Move' or 'Copy'

            vim.ui.input({
              prompt = string.format('%s %s to: ', action_name, state.clipboard),
            }, function(new_name)
              if new_name then
                operation(state, state.clipboard, vim.fs.joinpath(new_name, state.clipboard)).run()
              end
            end)
          end
        end,
      },
      {
        key = Config.keymaps.toogle_hidden,
        action = function()
          state.show_hidden = not state.show_hidden
          Notify.info(string.format('Hidden files %s', state.show_hidden and 'shown' or 'hidden'))
          Browser.refresh(state, state.current_path).run()
        end,
      },
      {
        key = Config.keymaps.forward,
        action = function()
          local pos = api.nvim_win_get_cursor(state.win)
          local count = api.nvim_buf_line_count(state.buf)
          pos[1] = pos[1] + 1 > count and 3 or pos[1] + 1
          api.nvim_win_set_cursor(state.win, pos)
          Browser.update_current_hl(state, pos[1] - 1)
        end,
      },
      {
        key = Config.keymaps.backward,
        action = function()
          local pos = api.nvim_win_get_cursor(state.win)
          local count = api.nvim_buf_line_count(state.buf)
          pos[1] = pos[1] - 1 < 3 and count or pos[1] - 1
          api.nvim_win_set_cursor(state.win, pos)
          Browser.update_current_hl(state, pos[1] - 1)
        end,
      },
    }

    local nmap = function(map)
      local key = map.key
      if type(map.key) ~= 'table' then
        key = {
          [map.mode or 'n'] = map.key,
        }
      end
      for m, key in pairs(key) do
        vim.keymap.set(m, key, function()
          api.nvim_win_call(state.win, function()
            map.action()
          end)
        end, { buffer = state.search_buf })
      end
    end

    Iter(keymaps):map(function(map)
      nmap(map)
    end)

    return state
  end)
end

Browser.refresh = function(state, path)
  return F.IO.fromEffect(function()
    local handle = uv.fs_scandir(path)
    if not handle then
      Notify.err('Failed to read directory')
      return
    end

    -- Helper function to collect directory entries
    local function collectEntries()
      local entries = {}
      while true do
        local name = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        table.insert(entries, name)
      end
      return entries
    end

    -- Filter and process entries
    local function processEntries(entries)
      return Iter(entries):map(function(name)
        if state.show_hidden or not name:match('^%.') then
          return name
        end
      end):totable()
    end

    -- Convert entries to tasks
    local function createStatTasks(filtered_entries)
      return Iter(filtered_entries):map(function(name)
        return {
          name = name,
          path = vim.fs.joinpath(path, name),
        }
      end):totable()
    end

    local entries = collectEntries()
    local filtered = processEntries(entries)
    local tasks = createStatTasks(filtered)
    local pending = { count = #tasks }
    local collected_entries = {}

    -- Execute stat operations
    for _, task in ipairs(tasks) do
      uv.fs_stat(task.path, function(err, stat)
        if not err and stat then
          table.insert(collected_entries, {
            name = task.name,
            stat = stat,
          })
        end
        pending.count = pending.count - 1

        if pending.count == 0 then
          vim.schedule(function()
            -- Sort entries
            table.sort(collected_entries, function(a, b)
              return a.name < b.name
            end)

            -- Format entries and calculate max width
            local function formatEntries()
              local max_width = 0
              local formatted = vim.tbl_map(function(entry)
                local line = UI.Entry.render(entry)
                max_width = math.max(max_width, #line)
                return line
              end, collected_entries)
              return formatted, max_width + 5
            end

            -- Update buffer content
            local function updateBuffer(formatted_entries)
              vim.bo[state.buf].modifiable = true
              api.nvim_buf_set_lines(state.buf, 2, -1, false, formatted_entries)
              vim.bo[state.buf].modifiable = false
            end

            -- Update highlights
            local function updateHighlights()
              UI.Highlights.set_header_highlights(state.buf)
              for i, entry in ipairs(collected_entries) do
                UI.Highlights.set_entry_highlights(state.buf, i + 1, entry)
              end
            end

            local pos = api.nvim_win_get_cursor(state.search_win)
            local prompt_lnum = pos[1] - 1
            -- Execute all updates
            local formatted_entries, max_width = formatEntries()
            local cfg = api.nvim_win_get_config(state.win)
            cfg.width = max_width
            local new_col = math.floor((vim.o.columns - max_width) / 2)
            cfg.col = new_col
            -- when first open set prompt line number to 0
            if cfg.hide then
              prompt_lnum = 0
            end
            cfg.hide = false
            api.nvim_win_set_config(state.win, cfg)

            -- Update main window config
            cfg = api.nvim_win_get_config(state.search_win)
            cfg.width = max_width
            cfg.col = new_col
            cfg.hide = false
            api.nvim_win_set_config(state.search_win, cfg)

            updateBuffer(formatted_entries)
            updateHighlights()
            api.nvim_win_set_cursor(state.win, { 3, 1 })
            Browser.update_current_hl(state, 2)

            vim.fn.prompt_setprompt(state.search_buf, state.current_path)
            api.nvim_buf_set_extmark(state.search_buf, ns_id, prompt_lnum, 0, {
              line_hl_group = 'DiredPrompt',
            })
            -- Update state
            state.entries = collected_entries
          end)
        end
      end)
    end

    return state
  end)
end

-- Main entry point
local function browse_directory(path)
  if not path:find(SEPARATOR .. '$') then
    path = path .. SEPARATOR
  end

  F.IO
    .chain(Browser.State.create(path), function(state)
      return F.IO.chain(Browser.setup(state), function(s)
        return Browser.refresh(s, path)
      end)
    end)
    .run()
end

return { browse_directory = browse_directory }
