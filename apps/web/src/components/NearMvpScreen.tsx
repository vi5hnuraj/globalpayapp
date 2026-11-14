import CheckCircleOutline from "@mui/icons-material/CheckCircleOutlined";
import OpenInNew from "@mui/icons-material/OpenInNew";
import Alert from "@mui/material/Alert";
import CircularProgress from "@mui/material/CircularProgress";
import Link from "@mui/material/Link";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import { useEffect, useState } from "react";
import { api, type NearAccount, type NearConfig } from "../lib/api";
import { GroupedBlock, GroupedDetail, GroupedList } from "./Grouped";

const DEMO_ACCOUNT = "demo.globalpay-receipts.testnet";
const TXS = [
  ["Deploy safe vault", "HrE6Ai9zL4HpEJC1kVKpzXMyLE6jidKgKAn4FobnXyy1"],
  ["Lock with ft_transfer_call", "73W2bhLAyD28getf1XWVUcmBZ6632uriwnVjXuF12S7a"],
  ["Callback-safe refund", "2WHh1PxWyFouUeqhw1tTkLZJRLVit5nsUzNmWqPatK4n"],
  ["Failed refund restored", "574Q444RCD1oNeYVmDzHV7rN3WCqqeLkV2Kv6YGp2KfV"],
  ["Successful retry", "6UnQ8ssJGkw8v2661Tvp4dfoBXZMrCpkzd4BaVEsTfvC"],
  ["Flutter-signed lock", "D7ULnQkgMtCrNi3Br3mda2fnwyR5PZNhkt4gyJGZFqRp"],
  ["Flutter-signed refund", "BRAkBMCQ1uA3ri7cb77KnPsbZEYR4W288vigqVYXyPAW"],
  ["Treasury migration", "H1tjXKJNyFWuagM2aZDrskKhUrhNk71VRERmheErzUyE"],
  ["Synthetic no-INR settlement", "29hecU8F96d476ZuRrcNdZCGVZ7BQZGHHaSZJonjqsys"],
] as const;

export default function NearMvpScreen() {
  const [config, setConfig] = useState<NearConfig | null>(null);
  const [account, setAccount] = useState<NearAccount | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    Promise.all([api.nearConfig(), api.nearAccount(DEMO_ACCOUNT)])
      .then(([nextConfig, nextAccount]) => {
        if (!active) return;
        setConfig(nextConfig);
        setAccount(nextAccount);
      })
      .catch((reason: Error) => active && setError(reason.message));
    return () => { active = false; };
  }, []);

  if (error) return <Alert severity="error">{error}</Alert>;
  if (!config || !account) {
    return <Stack sx={{ alignItems: "center", py: 8 }}><CircularProgress aria-label="Loading NEAR status" /></Stack>;
  }

  return (
    <Stack spacing={2.5} sx={{ pt: 1 }}>
      <Stack spacing={0.75}>
        <Typography variant="caption" color="text.secondary">NEAR HACKATHON MVP</Typography>
        <Typography variant="h4" component="h2">Real NEAR escrow, inside GlobalPay</Typography>
        <Typography color="text.secondary">
          The internal Android wallet signs native NEAR transactions. No browser wallet is required.
        </Typography>
      </Stack>

      <Alert severity="info">
        {config.token.symbol} is a permissionless testnet asset, not production Circle USDC. A lock does not mean INR reached a merchant.
      </Alert>

      <GroupedList aria-label="Live NEAR status">
        <GroupedBlock>
          <Stack direction="row" spacing={1.5} sx={{ alignItems: "center" }}>
            <CheckCircleOutline color="success" />
            <div>
              <Typography variant="h6">Verified on {config.networkId}</Typography>
              <Typography variant="body2" color="text.secondary">Final block {config.latestBlockHeight}</Typography>
            </div>
          </Stack>
        </GroupedBlock>
        <GroupedDetail label="Internal account" value={account.accountId} />
        <GroupedDetail label="Test-token balance" value={`${account.tokenBalanceFormatted} ${account.symbol}`} />
        <GroupedDetail label="NEAR balance" value={`${account.nearBalanceFormatted} NEAR`} />
        <GroupedDetail label="Token contract" value={config.token.accountId} />
        <GroupedDetail label="Escrow contract" value={config.vaultAccountId} />
        <GroupedDetail label="Crypto treasury" value={config.treasuryAccountId} />
        <GroupedDetail
          label="INR payout rail"
          value={config.capabilities.merchantPayout ? "RazorpayX enabled" : "Disabled in this deployment"}
        />
        <GroupedDetail label="Token storage" value={account.storageRegistered ? "Registered" : "Not registered"} />
      </GroupedList>

      <Stack spacing={1}>
        <Typography variant="h6" component="h3">On-chain evidence</Typography>
        {TXS.map(([label, hash]) => (
          <Link
            key={hash}
            href={`${config.explorer.replace(/\/$/, "")}/transactions/${hash}`}
            target="_blank"
            rel="noopener noreferrer"
            sx={{ display: "inline-flex", alignItems: "center", gap: 0.75, overflowWrap: "anywhere" }}
          >
            {label} <OpenInNew sx={{ fontSize: 15 }} />
          </Link>
        ))}
      </Stack>

      <Alert severity="warning">
        Treasury settlement is deployed and callback-safe. The settlement above used synthetic test evidence and did not send INR;
        no live RazorpayX merchant payout is claimed.
      </Alert>
    </Stack>
  );
}
