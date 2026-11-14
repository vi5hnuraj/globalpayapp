import AccountBalanceWalletOutlined from "@mui/icons-material/AccountBalanceWalletOutlined";
import Alert from "@mui/material/Alert";
import Button from "@mui/material/Button";
import Box from "@mui/material/Box";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import { useTheme } from "@mui/material/styles";
import { isMobileDevice, metaMaskDeepLink, type WalletOption } from "../lib/wallet";

interface Props {
  wallets: WalletOption[];
  connecting: boolean;
  error: string | null;
  onConnect: (wallet: WalletOption) => void;
}

export default function ConnectScreen({ wallets, connecting, error, onConnect }: Props) {
  const theme = useTheme();
    const PRIMARY_MAIN = theme.palette.primary.main;
  const PRIMARY_CONTRAST = theme.palette.primary.contrastText;
  const TEXT_PRIMARY = theme.palette.text.primary;
  const TEXT_SECONDARY = theme.palette.text.secondary;

  return (
    <Box className="rr-stagger" sx={{ pt: 4, pb: 4 }}>
      {/* Hero/Landing section - GlobalPay style */}
      <Box sx={{ textAlign: "center", px: 2, mb: 6 }}>
        <Typography variant="h2" component="h2" sx={{ color: TEXT_PRIMARY, mb: 1 }}>
          Pay any UPI QR with stablecoins
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 560, mx: "auto", mb: 4 }}>
          Scan any UPI QR code and pay from your stablecoin wallet. The merchant receives ordinary INR. You don't pay any gas.
        </Typography>
        <Typography variant="body2" sx={{ fontSize: "0.875rem", opacity: 0.7, color: TEXT_SECONDARY }}>
          Testnet · Arc + Whitechain
        </Typography>
      </Box>

      {/* Divider / tagline */}
      <Box sx={{ textAlign: "center", my: 4 }}>
        <Typography variant="body2" color="text.secondary" sx={{ opacity: 0.5 }}>
          · &
          ·
        </Typography>
      </Box>

      {/* Wallet connect CTA - primary button in GlobalPay blue */}
      <Box sx={{ textAlign: "center", mb: 4 }}>
        <Button
          variant="contained"
          size="large"
          sx={{ bgcolor: PRIMARY_MAIN, color: PRIMARY_CONTRAST, width: "100%", fontWeight: 600 }}
          disabled={connecting}
          onClick={() => wallets.length > 0 ? onConnect(wallets[0]) : null}
        >
          {connecting ? "Connecting…" : "Connect Wallet"}
        </Button>
      </Box>

      {/* PayTag input section */}
      <Box sx={{ textAlign: "center", mb: 6 }}>
        <Typography variant="body1" color="text.secondary" sx={{ marginBottom: 1, display: "block" }}>
          Or connect via @paytag
        </Typography>
        <Box sx={{ mt: 2, gap: 1, justifyContent: "center" }}>
          <Button variant="outlined" size="small" disableElevation>
            <AccountBalanceWalletOutlined fontSize="small" /> @globalpay
          </Button>
        </Box>
      </Box>

      {/* Error state */}
      {error && <Alert severity="error" sx={{ mt: 3, width: "100%" }}>{error}</Alert>}

      {/* No wallets state - mobile vs desktop */}
      {wallets.length > 0 ? (
        <Stack spacing={1.5} sx={{ textAlign: "center" }}>
          {wallets.map((wallet) => (
            <Button
              key={wallet.id}
              variant="outlined"
              size="large"
              sx={{
                width: "100%",
                bgcolor: "transparent",
                border: `1px solid ${PRIMARY_MAIN}`,
                color: PRIMARY_MAIN,
                "&:hover": { backgroundColor: "color-mix(in srgb, var(--mui-palette-primary-main) 8%, transparent)" },
                "@media (hover: hover) and (pointer: fine)": {
                  "&:hover": { backgroundColor: "color-mix(in srgb, var(--mui-palette-primary-main) 8%, transparent)" },
                },
              }}
              onClick={() => onConnect(wallet)}
            >
              Connect {wallet.name}
            </Button>
          ))}
        </Stack>
      ) : isMobileDevice() ? (
        <Stack spacing={1.5} sx={{ textAlign: "center" }}>
          <Button
            variant="contained"
            size="large"
            sx={{ bgcolor: PRIMARY_MAIN, color: PRIMARY_CONTRAST, width: "100%" }}
            href={metaMaskDeepLink(new URL(window.location.href))}
          >
            Open in MetaMask
          </Button>
          <Typography variant="body2" color="text.secondary" sx={{ mt: 1, fontSize: "0.875rem" }}>
            GlobalPay runs inside your wallet's browser on phones. If you use another wallet, open this page in its browser.
          </Typography>
        </Stack>
      ) : (
        <Alert severity="info" sx={{ mt: 3, width: "100%" }}>
          No wallet found. Install a browser wallet such as MetaMask, then reload this page.
        </Alert>
      )}
    </Box>
  );
}