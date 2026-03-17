if vim.g.loaded_agentation_plugin == 1 then
  return
end

vim.g.loaded_agentation_plugin = 1

require("agentation").setup()
