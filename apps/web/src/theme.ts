import { createTheme } from "@mui/material/styles";

declare module "@mui/material/styles" {
  interface TypeBackground {
    surface: string;
    surfacePress: string;
  }
}

const EASE_OUT = "cubic-bezier(0.23, 1, 0.32, 1)";

/*
 * GlobalPay's design, taken from the live site (globalpay.web.app): warm paper, near-black ink, an
 * electric yellow for anything selected, and green only for success. The faces are bundled through
 * @fontsource, so nothing is fetched at runtime. Neither of the two faces carries the ₹ sign, so
 * Roboto's latin-ext sits behind them in the stack purely for that glyph.
 */
const TEXT = '"Instrument Sans", Roboto, "Helvetica Neue", Arial, sans-serif';
const DISPLAY = '"Bricolage Grotesque", "Instrument Sans", Roboto, system-ui, sans-serif';
const MONO = '"JetBrains Mono", ui-monospace, Menlo, monospace';

/** The primary button hover: the ink warms a little in light, cools a little in dark. */
const BTN_HOVER = "color-mix(in srgb, var(--mui-palette-primary-main) 92%, var(--mui-palette-background-default))";
/** The tonal background of a secondary action. */
const BTN_TINT = "color-mix(in srgb, var(--mui-palette-primary-main) 8%, transparent)";

/** GlobalPay's colour roles on top of MUI, following the device's light or dark setting. */
export const theme = createTheme({
  cssVariables: { colorSchemeSelector: "media" },
  colorSchemes: {
    light: {
      palette: {
        primary: { main: "#171914", contrastText: "#F6F5EF" },
        secondary: { main: "#FFE600", contrastText: "#171914" },
        background: { default: "#F6F5EF", paper: "#FFFEF9", surface: "#EEEFE6", surfacePress: "#E9EADF" },
        text: { primary: "#171914", secondary: "#62665C" },
        divider: "#DEDFD5",
        success: { main: "#36744A" },
        warning: { main: "#8F6B00" },
        error: { main: "#C0392B" },
        info: { main: "#62665C" },
      },
    },
    // The site's `--night` tone: the same paper and ink, read in the dark.
    dark: {
      palette: {
        primary: { main: "#F6F5EF", contrastText: "#171914" },
        secondary: { main: "#FFE600", contrastText: "#171914" },
        background: { default: "#171C18", paper: "#1E241F", surface: "#232A24", surfacePress: "#2C342D" },
        text: { primary: "#F6F5EF", secondary: "#B2B9AC" },
        divider: "#2E352F",
        success: { main: "#63A97C" },
        warning: { main: "#E8C25A" },
        error: { main: "#E8837A" },
        info: { main: "#B2B9AC" },
      },
    },
  },
  shape: { borderRadius: 16 },
  typography: {
    fontFamily: TEXT,
    allVariants: { fontVariantNumeric: "tabular-nums" },
    button: { textTransform: "none", fontWeight: 600, fontSize: "0.9375rem", letterSpacing: "0.01em" },
    body1: { fontSize: "1.0625rem", lineHeight: 1.6 },
    body2: { lineHeight: 1.6 },
    // The eyebrow: the site's mono label above a heading.
    caption: {
      fontFamily: MONO,
      fontSize: "0.6875rem",
      fontWeight: 500,
      lineHeight: 1.5,
      letterSpacing: "0.06em",
      textTransform: "uppercase",
    },
    h2: { fontFamily: DISPLAY, fontSize: "2.75rem", lineHeight: 1.02, fontWeight: 600, letterSpacing: "-0.055em" },
    h3: { fontFamily: DISPLAY, fontSize: "2.5rem", lineHeight: 1.05, fontWeight: 600, letterSpacing: "-0.055em" },
    h4: { fontFamily: DISPLAY, fontSize: "2.125rem", lineHeight: 1.1, fontWeight: 600, letterSpacing: "-0.05em" },
    h5: { fontFamily: DISPLAY, fontSize: "1.625rem", lineHeight: 1.2, fontWeight: 600, letterSpacing: "-0.04em" },
    h6: { fontFamily: DISPLAY, fontWeight: 700, fontSize: "1.125rem", letterSpacing: "-0.05em" },
  },
  components: {
    MuiButton: {
      defaultProps: { disableElevation: true },
      styleOverrides: {
        root: {
          // The site's `.btn`: a pill that answers a press with a squeeze.
          borderRadius: 999,
          minHeight: 52,
          paddingInline: 24,
          transition: "transform 160ms " + EASE_OUT + ", background-color 150ms ease, border-color 150ms ease, color 150ms ease",
          "&:active:not(.Mui-disabled)": { transform: "scale(0.97)" },
          variants: [
            {
              props: { variant: "contained", color: "primary" },
              style: {
                border: "1px solid transparent",
                backgroundColor: "var(--mui-palette-primary-main)",
                color: "var(--mui-palette-primary-contrastText)",
                "&:hover": { borderColor: "transparent", backgroundColor: BTN_HOVER },
                "@media (hover: hover) and (pointer: fine)": { "&:hover": { backgroundColor: BTN_HOVER } },
                "&.Mui-disabled": {
                  borderColor: "transparent",
                  backgroundColor: "var(--mui-palette-action-disabledBackground)",
                  color: "var(--mui-palette-action-disabled)",
                },
              },
            },
            {
              props: { variant: "outlined", color: "primary" },
              style: {
                // Tonal rather than boxed: a secondary action reads as a soft fill, not an outline.
                border: "1px solid transparent",
                backgroundColor: BTN_TINT,
                color: "var(--mui-palette-primary-main)",
                "&:hover": { borderColor: "transparent", backgroundColor: BTN_TINT },
                "@media (hover: hover) and (pointer: fine)": { "&:hover": { backgroundColor: BTN_TINT } },
              },
            },
          ],
        },
        sizeLarge: { minHeight: 56, paddingInline: 28, fontSize: "1rem" },
      },
    },
    MuiButtonBase: {
      defaultProps: { disableRipple: true },
      styleOverrides: {
        root: {
          "&.Mui-focusVisible": { outline: "3px solid #7B5CCA", outlineOffset: 6 },
        },
      },
    },
    MuiIconButton: { styleOverrides: { root: { "&:active": { transform: "scale(0.97)" } } } },
    MuiChip: { styleOverrides: { root: { "&:active": { transform: "scale(0.97)" } } } },
    MuiToggleButtonGroup: {
      styleOverrides: {
        root: {
          gap: 3,
          "&& .MuiToggleButton-root": { margin: 0, border: 0, borderRadius: 6 },
          "&& .MuiToggleButton-root.MuiToggleButtonGroup-firstButton": { borderTopLeftRadius: 28, borderBottomLeftRadius: 28 },
          "&& .MuiToggleButton-root.MuiToggleButtonGroup-lastButton": { borderTopRightRadius: 28, borderBottomRightRadius: 28 },
        },
      },
    },
    MuiToggleButton: {
      styleOverrides: {
        root: {
          minHeight: 56,
          paddingInline: 16,
          textTransform: "none",
          backgroundColor: "var(--mui-palette-background-default)",
          "&:hover": { backgroundColor: "var(--mui-palette-background-default)" },
          "@media (hover: hover) and (pointer: fine)": { "&:hover": { backgroundColor: "var(--mui-palette-background-surfacePress)" } },
          "&:active": { transform: "scale(0.97)" },
          // Selection is the yellow, as it is everywhere on the site.
          "&&.Mui-selected, &&.Mui-selected:hover": {
            backgroundColor: "var(--mui-palette-secondary-main)",
            color: "var(--mui-palette-secondary-contrastText)",
          },
        },
      },
    },
    // Inputs sit on the white card, as the site's fields do, rather than on the page paper.
    MuiOutlinedInput: { styleOverrides: { root: { backgroundColor: "var(--mui-palette-background-paper)" } } },
    MuiCircularProgress: { styleOverrides: { root: { animationDuration: "900ms" } } },
    MuiTooltip: { defaultProps: { enterDelay: 400, enterNextDelay: 0, slotProps: { transition: { timeout: 125 } } } },
    MuiDialog: {
      defaultProps: { transitionDuration: { enter: 200, exit: 130 } },
      styleOverrides: { paper: { borderRadius: 24 } },
    },
    MuiPaper: { styleOverrides: { rounded: { borderRadius: 16 } } },
    MuiTextField: { defaultProps: { fullWidth: true } },
    MuiListItemButton: { styleOverrides: { root: { "&:active": { transform: "scale(0.97)" } } } },
    MuiBottomNavigation: { styleOverrides: { root: { height: 72, backgroundColor: "transparent" } } },
    MuiBottomNavigationAction: {
      styleOverrides: {
        root: {
          minHeight: 64,
          paddingInline: 12,
          transition: "transform 160ms " + EASE_OUT + ", color 120ms ease",
          "&:active": { transform: "scale(0.97)" },
          "& .MuiSvgIcon-root": {
            boxSizing: "content-box",
            padding: "4px 18px",
            marginBottom: 2,
            borderRadius: 999,
            transition: "background-color 120ms ease",
          },
          "&:active .MuiSvgIcon-root": { transform: "scale(0.97)" },
          "&.Mui-selected": { paddingInline: 12 },
          "&.Mui-selected .MuiSvgIcon-root": { backgroundColor: "var(--mui-palette-secondary-main)" },
          "&.Mui-selected, &.Mui-selected .MuiBottomNavigationAction-label": {
            color: "var(--mui-palette-text-primary)",
          },
        },
        label: {
          fontSize: "0.75rem",
          transition: "none",
          fontFamily: DISPLAY,
          letterSpacing: "-0.02em",
          "&.Mui-selected": { fontSize: "0.75rem", fontWeight: 700 },
        },
      },
    },
  },
});
