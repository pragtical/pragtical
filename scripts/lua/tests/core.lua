local test = require "core.test"
local core = require "core"
local Node = require "core.node"
local RootView = require "core.rootview"

local function add_doc(name, dirty, context)
  local doc = {
    name = name, dirty = dirty, closed = 0,
    is_dirty = function(self) return self.dirty end,
    get_name = function(self) return self.name end,
    on_close = function(self)
      test.equal(#core.get_views_referencing_doc(self), 0)
      self.closed = self.closed + 1
    end
  }
  core.docs[#core.docs + 1] = doc
  local views = core.root_view.root_node.views
  views[#views + 1] = { doc = doc, context = context or "session" }
  return doc
end

test.describe("core project switching", function()
  local fields = {
    "docs", "projects", "recent_projects", "nag_view", "root_view",
    "set_project", "exit", "collect_garbage"
  }

  test.before_each(function(c)
    c.saved = {}
    for _, key in ipairs(fields) do c.saved[key] = core[key] end
    c.chdir = system.chdir
    c.prompts, c.switches, c.exits = {}, 0, 0
    core.docs, core.recent_projects = {}, {}
    core.projects = { { path = USERDIR } }
    core.collect_garbage = false
    local permanent_view = { context = "application" }
    core.root_view = setmetatable({
      root_node = setmetatable({
        type = "leaf", views = { permanent_view }, active_view = permanent_view
      }, Node)
    }, RootView)
    core.set_project = function(path)
      c.switches = c.switches + 1
      core.projects = { { path = path } }
      return core.projects[1]
    end
    core.nag_view = { show = function(_, _, message, options, callback)
      c.prompts[#c.prompts + 1] = { message = message, callback = callback }
    end }
    -- Exercise restart's real confirmation path without exiting the test process
    -- or writing its session once confirmation succeeds.
    core.exit = function(quit_fn, force)
      if force then
        c.exits = c.exits + 1
      else
        c.saved.exit(quit_fn, force)
      end
    end
    system.chdir = function(path) c.directory = path end
  end)

  test.after_each(function(c)
    for _, key in ipairs(fields) do core[key] = c.saved[key] end
    system.chdir = c.chdir
  end)

  test.test("accepting a project switch prompts only once", function(c)
    local edited = add_doc("edited.txt", true)
    local other = add_doc("other.txt", true)
    local clean = add_doc("clean.txt", false)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    test.equal(#c.prompts, 1)
    c.prompts[1].callback({ text = "Yes" })

    test.equal(#c.prompts, 1)
    test.equal(c.switches, 1)
    test.equal(c.exits, 1)
    test.equal(#core.docs, 0)
    test.equal(c.directory, USERDIR)
    test.equal(core.collect_garbage, true)
    for _, doc in ipairs { edited, other, clean } do
      test.equal(doc.closed, 1)
    end
    test.equal(edited:is_dirty(), true)
  end)

  test.test("declining leaves the project and dirty documents intact", function(c)
    local doc = add_doc("edited.txt", true)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    c.prompts[1].callback({ text = "No" })

    test.equal(#c.prompts, 1)
    test.equal(c.switches, 0)
    test.equal(c.exits, 0)
    test.equal(doc.closed, 0)
    test.equal(doc:is_dirty(), true)
    test.equal(#core.docs, 1)
    test.equal(#core.get_views_referencing_doc(doc), 1)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    test.equal(#c.prompts, 2)
  end)

  test.test("clean documents are closed before restarting without a prompt", function(c)
    local doc = add_doc("clean.txt", false)
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    test.equal(#c.prompts, 0)
    test.equal(c.switches, 1)
    test.equal(c.exits, 1)
    test.equal(#core.docs, 0)
    test.equal(doc.closed, 1)
  end)

  test.test("restart still warns about dirty documents with surviving views", function(c)
    local closed = add_doc("closed.txt", true)
    local retained = add_doc("retained.txt", true, "application")
    core.confirm_close_docs(core.docs, core.open_project, USERDIR)
    c.prompts[1].callback({ text = "Yes" })

    test.equal(#c.prompts, 2)
    test.match(c.prompts[2].message, '"retained.txt"', nil, true)
    test.equal(c.exits, 0)
    test.equal(#core.docs, 1)
    test.equal(core.docs[1], retained)
    test.equal(closed.closed, 1)
    test.equal(retained.closed, 0)
    test.equal(retained:is_dirty(), true)
  end)
end)
