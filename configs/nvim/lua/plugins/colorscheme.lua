-- LazyVim's default colorscheme (tokyonight), made transparent so the
-- wallpaper / terminal background shows through — no solid editor background.
return {
  {
    "folke/tokyonight.nvim",
    opts = {
      style = "night",
      transparent = true,
      styles = {
        sidebars = "transparent",
        floats = "transparent",
      },
    },
  },
  {
    "LazyVim/LazyVim",
    opts = { colorscheme = "tokyonight" },
  },
}
