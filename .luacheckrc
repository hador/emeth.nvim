std = "luajit"
globals = { "vim" }
max_line_length = 140

ignore = {
  -- Scoped to `self`: a plain unused argument fails the typecheck job.
  "212/self", -- unused `self` argument
  "631", -- line too long
}

exclude_files = {
  ".luarocks",
}
