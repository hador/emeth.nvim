std = "luajit"
globals = { "vim" }
max_line_length = 140

ignore = {
  "212", -- unused argument
  "631", -- line too long
}

exclude_files = {
  ".luarocks",
}
