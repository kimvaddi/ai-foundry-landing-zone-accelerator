"""
Architecture diagram generator for the AI Foundry Landing Zone Accelerator.

Uses the `diagrams` library (mingrammer/diagrams) with the official Azure
icon set. Produces three PNGs under docs/images/:

  1. solution-overview.png  - high-level "at a glance" view
  2. spoke-standalone.png   - spoke topology, standalone mode
  3. request-lifecycle.png  - request dataflow through the AI Gateway

Prereqs:
    pip install diagrams
    winget install Graphviz.Graphviz   # (or: brew install graphviz / apt)

Regenerate:
    cd docs/diagrams
    python generate.py
"""
from __future__ import annotations

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.azure.aimachinelearning import (
    AzureOpenai,
    CognitiveSearch,
    ContentModerators,
)
from diagrams.azure.containers import ContainerInstances, ContainerRegistries
from diagrams.azure.database import CosmosDb
from diagrams.azure.general import Resource, Subscriptions, Usericon
from diagrams.azure.identity import ManagedIdentities
from diagrams.azure.integration import APIManagement
from diagrams.azure.monitor import (
    ApplicationInsights,
    AzureWorkbooks,
    LogAnalyticsWorkspaces,
    Monitor,
)
from diagrams.azure.network import (
    ApplicationGateway,
    DNSPrivateZones,
    Firewall,
    PrivateEndpoint,
    Subnets,
    VirtualNetworks,
)
from diagrams.azure.security import KeyVaults, MicrosoftDefenderForCloud
from diagrams.azure.storage import BlobStorage


OUTPUT_DIR = Path(__file__).resolve().parents[1] / "images"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


# Azure brand-aligned cluster palette
HUB_BG = "#E1F5FE"        # light blue - existing hub
SPOKE_BG = "#FFFFFF"       # white - what we deploy
PLATFORM_BG = "#F3E5F5"    # lavender - platform RG
FOUNDRY_BG = "#FFF8E1"     # warm beige - Foundry RG
GOVERNANCE_BG = "#E8F5E9"  # light green - policy + finops
SAFETY_BG = "#FFEBEE"      # light pink - content safety
CLIENT_BG = "#ECEFF1"      # slate - client side

CLUSTER_STYLE = {
    "fontsize": "14",
    "fontname": "Segoe UI Semibold",
    "labelloc": "t",
    "style": "rounded,filled",
    "penwidth": "2",
}

NODE_ATTR = {
    "fontsize": "11",
    "fontname": "Segoe UI",
}

EDGE_ATTR = {
    "fontsize": "10",
    "fontname": "Segoe UI",
}


def cluster_attrs(label: str, bgcolor: str, border: str) -> dict:
    """Build cluster graph_attr dict with light fill + dark border."""
    return {
        **CLUSTER_STYLE,
        "bgcolor": bgcolor,
        "pencolor": border,
        "label": label,
    }


# Back-compat alias used below
hub_cluster_attrs = cluster_attrs


# ---------------------------------------------------------------------------
# Diagram 1: solution overview - component layout (no flow noise)
# ---------------------------------------------------------------------------
def solution_overview() -> None:
    out = OUTPUT_DIR / "solution-overview"
    with Diagram(
        "Azure AI Foundry Landing Zone - Solution Overview",
        filename=str(out),
        show=False,
        direction="TB",
        outformat="png",
        graph_attr={
            "fontsize": "18",
            "fontname": "Segoe UI Bold",
            "bgcolor": "white",
            "pad": "0.5",
            "splines": "spline",
            "nodesep": "0.5",
            "ranksep": "1.0",
            "compound": "true",
        },
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        with Cluster(
            "[OPTIONAL] Existing ALZ Hub (Connectivity subscription)",
            graph_attr=cluster_attrs(
                "[OPTIONAL] Existing ALZ Hub (Connectivity subscription)",
                HUB_BG,
                "#0288D1",
            ),
        ):
            hub_vnet = VirtualNetworks("Hub VNet")
            hub_fw = Firewall("Azure Firewall\n(egress)")
            hub_dns = DNSPrivateZones("Central Private\nDNS Zones")

        with Cluster(
            "Spoke subscription - deployed by this accelerator",
            graph_attr=cluster_attrs(
                "Spoke subscription - deployed by this accelerator",
                SPOKE_BG,
                "#1565C0",
            ),
        ):
            with Cluster(
                "RG: rg-{workload}-platform-{env}",
                graph_attr=cluster_attrs(
                    "RG: rg-{workload}-platform-{env}",
                    PLATFORM_BG,
                    "#7B1FA2",
                ),
            ):
                spoke_vnet = VirtualNetworks("Spoke VNet\n10.50.0.0/20\n(9 subnets)")
                pdns = DNSPrivateZones("21 Private DNS\nZones")
                appgw = ApplicationGateway("App Gateway + WAF\nOWASP 3.2")
                apim = APIManagement(
                    "APIM AI Gateway\nStandardV2 / Premium\ntoken-limit | cache\nsafety | metrics"
                )
                cae = ContainerInstances("Container Apps Env\nVNet-injected")
                kv = KeyVaults("Key Vault\nRBAC + purge-protect")
                law = LogAnalyticsWorkspaces(
                    "Log Analytics\n+ FinOps tables"
                )
                appi = ApplicationInsights("App Insights\nworkspace-based")

            with Cluster(
                "RG: rg-{workload}-foundry-{env}",
                graph_attr=cluster_attrs(
                    "RG: rg-{workload}-foundry-{env}",
                    FOUNDRY_BG,
                    "#F57C00",
                ),
            ):
                foundry = AzureOpenai(
                    "Foundry Account\nMI + disableLocalAuth\nPE-only"
                )
                proj1 = AzureOpenai("Project 1\nagent VNet inject")
                projN = AzureOpenai("Project N")
                search = CognitiveSearch("AI Search\nBasic / Standard")
                byor = BlobStorage("BYOR: Cosmos /\nStorage / KV / Search")
                cs = ContentModerators("Content Safety\n(per request)")

                foundry >> Edge(color="#F57C00") >> proj1
                foundry >> Edge(color="#F57C00") >> projN
                proj1 >> Edge(color="#F57C00") >> byor

        with Cluster(
            "Governance + FinOps (cross-cutting - applied to spoke)",
            graph_attr=cluster_attrs(
                "Governance + FinOps (cross-cutting - applied to spoke)",
                GOVERNANCE_BG,
                "#2E7D32",
            ),
        ):
            policy = MicrosoftDefenderForCloud(
                "Azure Policy Initiative\nmodel allowlist\nprivate-only | CMK"
            )
            workbooks = AzureWorkbooks(
                "Workbooks\nAgent perf | FinOps\nSafety | Compliance"
            )
            budgets = Monitor("Per-project budgets\n+ auto-suspend")
            otel = Monitor("OTel collector\nGenAI semconv")

        # Single representative edge per cluster pair - rank ordering
        spoke_vnet >> Edge(
            color="#7B1FA2", style="dashed", label="peer + UDR + PDNS link"
        ) >> hub_vnet
        # Governance applies to the spoke (single audit arrow per axis)
        policy >> Edge(
            color="#558B2F", style="dotted", label="audit"
        ) >> foundry
        workbooks >> Edge(
            color="#2E7D32", style="dotted", label="read"
        ) >> law

    print(f"Wrote {out.with_suffix('.png')}")


# ---------------------------------------------------------------------------
# Diagram 2: spoke standalone (greenfield)
# ---------------------------------------------------------------------------
def spoke_standalone() -> None:
    out = OUTPUT_DIR / "spoke-standalone"
    with Diagram(
        "Spoke Topology - Standalone Mode (Greenfield)",
        filename=str(out),
        show=False,
        direction="TB",
        outformat="png",
        graph_attr={
            "fontsize": "18",
            "fontname": "Segoe UI Bold",
            "bgcolor": "white",
            "pad": "0.4",
            "nodesep": "0.5",
            "ranksep": "0.7",
        },
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        client = Usericon("External\nclient")

        with Cluster(
            "Subscription (target sub) - networkMode = 'standalone'",
            graph_attr=hub_cluster_attrs(
                "Subscription (target sub) - networkMode = 'standalone'",
                SPOKE_BG,
                "#1565C0",
            ),
        ):
            with Cluster(
                "Spoke VNet 10.50.0.0/20 - 9 subnets",
                graph_attr=hub_cluster_attrs(
                    "Spoke VNet 10.50.0.0/20 - 9 subnets",
                    "#E3F2FD",
                    "#1565C0",
                ),
            ):
                appgw_sub = Subnets("snet-appgw\n/26 (+WAF)")
                apim_sub = Subnets("snet-apim\n/27 (StandardV2/Premium)")
                pe_sub = Subnets("snet-private-endpoints\n/26")
                agent_sub = Subnets("snet-agent\n/24 (Foundry inject)")
                cae_sub = Subnets("snet-cae\n/23 (Container Apps)")
                build_sub = Subnets("snet-build\n/27 (BuildVM)")
                bastion_sub = Subnets("AzureBastionSubnet\n/26")
                jump_sub = Subnets("snet-jump\n/27")
                util_sub = Subnets("snet-util\n/27 (DNS resolver)")

            with Cluster(
                "RG: platform - shared services",
                graph_attr=hub_cluster_attrs(
                    "RG: platform - shared services",
                    PLATFORM_BG,
                    "#7B1FA2",
                ),
            ):
                appgw = ApplicationGateway("App Gateway\n+ WAF_v2")
                apim = APIManagement("APIM AI Gateway")
                cae = ContainerInstances("Container Apps Env")
                kv = KeyVaults("Key Vault")
                pdns = DNSPrivateZones("21 Private DNS Zones")
                law = LogAnalyticsWorkspaces("Log Analytics +\nFinOps tables")
                appi = ApplicationInsights("App Insights")

            with Cluster(
                "RG: foundry - AI workload",
                graph_attr=hub_cluster_attrs(
                    "RG: foundry - AI workload",
                    FOUNDRY_BG,
                    "#F57C00",
                ),
            ):
                foundry = AzureOpenai("Foundry Account")
                proj = AzureOpenai("Project(s)")
                search = CognitiveSearch("AI Search")
                cs = ContentModerators("Content Safety")
                mi = ManagedIdentities("User-Assigned MI")
                cosmos = CosmosDb("Cosmos DB\n(BYOR)")
                stg = BlobStorage("Storage\n(BYOR)")

        # Subnet to service binding (color: violet = NIC/inject, teal = PE)
        appgw_sub >> Edge(color="#7B1FA2", style="dashed") >> appgw
        apim_sub >> Edge(color="#7B1FA2", style="dashed") >> apim
        cae_sub >> Edge(color="#7B1FA2", style="dashed") >> cae
        agent_sub >> Edge(color="#7B1FA2", style="dashed", label="inject") >> proj

        # PE for everything (teal)
        pe_color = Edge(color="#00897B", style="dashed", label="PE")
        pe_sub >> Edge(color="#00897B", style="dashed") >> kv
        pe_sub >> Edge(color="#00897B", style="dashed") >> foundry
        pe_sub >> Edge(color="#00897B", style="dashed") >> search
        pe_sub >> Edge(color="#00897B", style="dashed") >> cosmos
        pe_sub >> Edge(color="#00897B", style="dashed") >> stg

        # Request flow (solid blue)
        client >> Edge(color="#1976D2", penwidth="2") >> appgw
        appgw >> Edge(color="#1976D2", penwidth="2") >> apim
        apim >> Edge(color="#1976D2", penwidth="2", label="MI") >> foundry
        apim >> Edge(color="#C62828", penwidth="2", label="check") >> cs
        foundry >> Edge(color="#1976D2") >> proj
        proj >> Edge(color="#1976D2") >> search
        proj >> Edge(color="#1976D2") >> cosmos
        proj >> Edge(color="#1976D2") >> stg
        mi >> Edge(color="#37474F", style="dotted", label="binds") >> foundry

        # Observability (green)
        for src in (foundry, apim, search, appgw, kv):
            src >> Edge(color="#2E7D32", style="dotted") >> law
        law >> Edge(color="#2E7D32") >> appi

    print(f"Wrote {out.with_suffix('.png')}")


# ---------------------------------------------------------------------------
# Diagram 3: request lifecycle
# ---------------------------------------------------------------------------
def request_lifecycle() -> None:
    out = OUTPUT_DIR / "request-lifecycle"
    with Diagram(
        "Request Lifecycle Through the AI Gateway",
        filename=str(out),
        show=False,
        direction="LR",
        outformat="png",
        graph_attr={
            "fontsize": "18",
            "fontname": "Segoe UI Bold",
            "bgcolor": "white",
            "pad": "0.4",
            "nodesep": "0.6",
            "ranksep": "1.0",
        },
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
    ):
        client = Usericon("Client\n(app / agent)")

        with Cluster(
            "Edge",
            graph_attr=hub_cluster_attrs("Edge", CLIENT_BG, "#455A64"),
        ):
            appgw = ApplicationGateway("App Gateway\nWAF OWASP 3.2\nTLS terminate")

        with Cluster(
            "APIM AI Gateway - policy chain",
            graph_attr=hub_cluster_attrs(
                "APIM AI Gateway - policy chain",
                "#E3F2FD",
                "#1565C0",
            ),
        ):
            apim_in = APIManagement("1. Inbound\nsubscription key\n+ JWT")
            cache_lookup = APIManagement("2. Semantic\ncache lookup")
            token_limit = APIManagement("3. Token-limit\nper sub key")
            cs = ContentModerators("4. Prompt shield +\ncontent safety")
            backend_select = APIManagement(
                "5. Backend\nselect + MI auth"
            )
            metrics = Monitor("6. Emit-token-metric\n+ cache store")

        with Cluster(
            "Foundry backend",
            graph_attr=hub_cluster_attrs(
                "Foundry backend",
                FOUNDRY_BG,
                "#F57C00",
            ),
        ):
            foundry = AzureOpenai("Foundry / AOAI\nGPT-4 / o3 /\nembeddings")
            grounding = CognitiveSearch("AI Search\n(grounding)")

        with Cluster(
            "Observability sinks",
            graph_attr=hub_cluster_attrs(
                "Observability sinks",
                GOVERNANCE_BG,
                "#2E7D32",
            ),
        ):
            law = LogAnalyticsWorkspaces("Log Analytics\n+ FinOps tables")
            appi = ApplicationInsights("App Insights\n(GenAI semconv)")
            workbook = AzureWorkbooks("FinOps + Safety\nworkbooks")

        # Linear flow
        client >> Edge(color="#1976D2", penwidth="2.5", label="HTTPS") >> appgw
        appgw >> Edge(color="#1976D2", penwidth="2.5") >> apim_in
        apim_in >> Edge(color="#1976D2", penwidth="2") >> cache_lookup
        cache_lookup >> Edge(color="#1976D2", penwidth="2") >> token_limit
        token_limit >> Edge(color="#1976D2", penwidth="2") >> cs
        cs >> Edge(color="#1976D2", penwidth="2") >> backend_select
        backend_select >> Edge(color="#1976D2", penwidth="2", label="MI") >> foundry
        foundry >> Edge(color="#1976D2", style="dashed", label="optional") >> grounding
        foundry >> Edge(color="#1976D2", penwidth="2", label="200 / SSE") >> metrics
        metrics >> Edge(color="#1976D2", penwidth="2", label="resp") >> client

        # Tap to observability (green)
        metrics >> Edge(color="#2E7D32", style="dotted", label="tokens") >> law
        cs >> Edge(color="#C62828", style="dotted", label="verdict") >> law
        foundry >> Edge(color="#2E7D32", style="dotted", label="diag") >> law
        law >> Edge(color="#2E7D32") >> workbook
        backend_select >> Edge(color="#2E7D32", style="dotted") >> appi

    print(f"Wrote {out.with_suffix('.png')}")


if __name__ == "__main__":
    solution_overview()
    spoke_standalone()
    request_lifecycle()
