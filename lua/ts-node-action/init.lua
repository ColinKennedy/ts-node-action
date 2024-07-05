local M = {}

--- @private
--- @param replacement string|table
--- @param opts { cursor: { col: number, row: number }, callback: function, format: boolean, target: TSNode }
--- All opts fields are optional
local function replace_node(node, replacement, opts)
  if type(replacement) ~= "table" then
    replacement = { replacement }
  end

  local start_row, start_col, end_row, end_col = (opts.target or node):range()
  vim.api.nvim_buf_set_text(
    vim.api.nvim_get_current_buf(),
    start_row,
    start_col,
    end_row,
    end_col,
    replacement
  )

  if opts.cursor then
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), {
      start_row + (opts.cursor.row or 0) + 1,
      start_col + (opts.cursor.col or 0),
    })
  end

  if opts.format then
    vim.cmd("silent! normal! " .. #replacement .. "==")
  end

  if opts.callback then
    opts.callback()
  end
end

--- @private
--- @param message string
--- @return nil
local function info(message)
  vim.notify(
    message,
    vim.log.levels.INFO,
    { title = "Node Action", icon = " " }
  )
end

--- @private
--- @param action function
--- @param node TSNode
--- @return nil
local function do_action(action, node)
  local replacement, opts = action(node)
  if replacement then
    replace_node(node, replacement, opts or {})
  end
end

--- @param node TSNode
--- @param lang string
--- @return function|nil
local function find_action(node, lang)
  local type = node:type()

  if M.node_actions[lang] and M.node_actions[lang][type] then
    return M.node_actions[lang][type]
  else
    return M.node_actions["*"][type]
  end
end


local function find_action_function_by_name(node, lang, action_name)
  local type_ = node:type()
  local actions = nil

  if M.node_actions[lang] and M.node_actions[lang][type_] then
    actions = M.node_actions[lang][type_]
  else
    actions = M.node_actions["*"][type_]
  end

  if type(actions) ~= "table" then
    return nil
  end

  for _, action in ipairs(actions)
  do
    if action.name == action_name
    then
      return action[1]
    end
  end

  return nil
end

M.node_actions = require("ts-node-action.filetypes")

--- @param opts? table
--- @return nil
function M.setup(opts)
  M.node_actions = vim.tbl_deep_extend("force", M.node_actions, opts or {})

  vim.api.nvim_create_user_command(
    "NodeAction",
    M.node_action,
    { desc = "Performs action on the node under the cursor." }
  )

  vim.api.nvim_create_user_command(
    "NodeActionDebug",
    M.debug,
    { desc = "Prints debug information for Ts-Node-Action Plugin" }
  )
end

--- @private
--- @return TSNode, string
--- @return nil
function M._get_node()
  local root_langtree = require("nvim-treesitter.parsers").get_parser()
  if not root_langtree then
    return
  end

  local lnum, col = unpack(vim.api.nvim_win_get_cursor(0))
  local range4 = { lnum - 1, col, lnum - 1, col }
  local langtree = root_langtree:language_for_range(range4)
  local node = langtree:named_node_for_range(range4)
  return node, langtree:lang()
end

M.node_action = require("ts-node-action.repeat").set(function()
  local node, lang = M._get_node()
  if not node then
    info("No node found at cursor")
    return
  end

  local action = find_action(node, lang)
  if type(action) == "function" then
    do_action(action, node)
  elseif type(action) == "table" then
    if action.ask == false or #action == 1 then
      for _, act in ipairs(action) do
        do_action(act[1], node)
      end
    else
      vim.ui.select(action, {
        prompt = "Select Action",
        format_item = function(choice)
          return choice.name
        end,
      }, function(choice)
        do_action(choice[1], node)
      end)
    end
  else
    info(
      "No action defined for '"
        .. lang
        .. "' node type: '"
        .. node:type()
        .. "'"
    )
  end
end)

--- Find all children that fit within `range`.
---
--- Important:
---     This function is **inclusive**, the ``root`` is returned as the first index.
---
--- @param root TSNode A Neovim tree-sitter node to check within.
--- @param range Range2 The 0-or-more treesitter start/end index lines.
--- @return TSNode[] # The found children, if any.
---
local function _traverse_within_range(root, range)
  local start, end_ = unpack(range)

  local stack = {root}
  local output = {}

  while not vim.tbl_isempty(stack)
  do
    local current = table.remove(stack)

    table.insert(output, current)

    for child in current:iter_children()
    do
      if child:start() <= end_ and child:end_() >= start then
        -- NOTE: ``child`` is in range
        table.insert(stack, child)
      end
    end
  end

  return output
end

--- @class _NodeData
---     A description of the injected data and its root.
--- @field node
---     The starting root node for this injected language.
--- @field language
---     The name of the injected language.
---

--- Find all injected languages in `parser`.
---
--- @param parser vim.treesitter.LanguageTree
---     A starting tree to get all injections / trees.
--- @return table<string, string>
---     The found injections, if any.
---
local function _initialize_injections(parser)
  local injections = {} ---@type table<string, vim.treesitter.dev.Injection>

  parser:for_each_tree(function(parent_tree, parent_ltree)
    local parent = parent_tree:root()
    for _, child in pairs(parent_ltree:children()) do
      for _, tree in pairs(child:trees()) do
        local r = tree:root()
        local node = assert(parent:named_descendant_for_range(r:range()))
        local id = node:id()
        if not injections[id] or r:byte_length() > injections[id].root:byte_length() then
          injections[id] = child:lang()
        end
      end
    end
  end)

  return injections
end

--- Find all nodes within line `range` at `buffer`.
---
--- @param range Range2 The 0-or-more treesitter start/end index lines.
--- @param buffer number? A Vim buffer to query from. 0 == current buffer.
--- @return _NodeData[] # The found nodes, if any.
---
local function _get_nodes_in_range(range, buffer)
  local buffer = buffer or 0
  local parser = vim.treesitter.get_parser(buffer)
  local injections = _initialize_injections(parser)
  local trees = parser:parse(range)
  local buffer_language = parser:lang()

  local nodes = {}

  for _, tree in ipairs(trees)
  do
    local root = tree:root()
    local language = injections[root:id()] or buffer_language

    for _, node in ipairs(_traverse_within_range(root, range))
    do
      table.insert(nodes, {node=node, language=language})
    end
  end

  return nodes
end

M.run_action_on_visual_lines = require("ts-node-action.repeat").set(function(action_name)
  local buffer = vim.fn.bufnr()
  local region = vim.fn.getregionpos(vim.fn.getpos("."), vim.fn.getpos("v"), {type="V"})
  local vim_start_line = region[1]
  local vim_end_line = region[2]
  local treesitter_start_line = vim_start_line - 1
  local treesitter_end_line = vim_end_line - 1

  local nodes = _get_nodes_in_range(
    {treesitter_start_line, treesitter_end_line},
    buffer
  )

  for _, entry in ipairs(nodes)
  do
    local node = entry.node
    local lang = entry.language
    local action = find_action_function_by_name(node, lang, action_name)

    if type(action) == "function" then
      do_action(action, node)
    end
  end
end)

function M.available_actions()
  local node, lang = M._get_node()
  if not node then
    info("No node found at cursor")
    return
  end

  local function format_action(tbl)
    return {
      action = function()
        do_action(tbl[1], node)
      end,
      title = tbl.name or "Anonymous Node Action",
    }
  end

  local action = find_action(node, lang)
  if type(action) == "function" then
    return { format_action({ action }) }
  elseif type(action) == "table" then
    return vim.tbl_map(format_action, action)
  end
end

function M.debug()
  local node, lang = M._get_node()
  if not node then
    info("No node found at cursor")
    return
  end

  print(vim.inspect({
    node = {
      lang = lang,
      filetype = vim.o.filetype,
      node_type = node:type(),
      named = node:named(),
      named_children = node:named_child_count(),
    },
    plugin = {
      node_actions = M.node_actions,
    },
  }))
end

return M
