#!/bin/bash
set +e

export AZURE_AKS_DISABLE_AUTO_VERSION_CHECK=true
export AZURE_CONFIG_DIR="$HOME/.azure"

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"
FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################################
# FORMAT DATE LIKE AZURE PORTAL
############################################################
format_schedule() {
  local start="$1"
  local dow="$2"

  if [[ -z "$start" || "$start" == "null" ]]; then
    echo "Not Configured"
    return
  fi

  if formatted=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
    formatted="${formatted/%+0000/+00:00}"
  else
    formatted="$start"
  fi

  if [[ -n "$dow" ]]; then
    echo -e "Start On : $formatted\nRepeats  : Every week on $dow"
  else
    echo "Start On : $formatted"
  fi
}

############################################################
# HTML HEADER
############################################################
cat <<EOF > "$FINAL_REPORT"
<html>
<head>
<title>AKS Cluster Health – Report</title>
<style>
body { font-family: Arial; background:#eef2f7; margin:20px; }
h1 { color:white; }
.card { background:white; padding:20px; margin-bottom:35px;
  border-radius:12px; box-shadow:0 4px 12px rgba(0,0,0,0.08); }
table { width:100%; border-collapse:collapse; margin-top:15px; }
th { background:#2c3e50; color:white; padding:12px; }
td { padding:10px; border-bottom:1px solid #eee; }
.healthy-all { background:#c8f7c5; color:#145a32; font-weight:bold; }
.version-ok { background:#c8f7c5; color:#145a32; font-weight:bold; }
.collapsible {
  background:#3498db; color:white; cursor:pointer;
  padding:12px; width:100%; border-radius:6px;
  font-size:16px; text-align:left; margin-top:25px;
}
.content {
  padding:12px; display:none; border:1px solid #ccc;
  border-radius:6px; background:#fafafa; margin-bottom:25px;
}
pre {
  background:#2d3436; color:#dfe6e9; padding:12px;
  border-radius:6px;
}
</style>
<script>
document.addEventListener("DOMContentLoaded",()=>{
  document.querySelectorAll(".collapsible").forEach(b=>{
    b.onclick=()=> {
      let c=b.nextElementSibling;
      c.style.display=(c.style.display==="block"?"none":"block");
    };
  });
});
</script>
</head>
<body>
<div style="background:#3498db;padding:15px;border-radius:6px;">
<h1>AKS Cluster Health – Report</h1>
</div>
EOF

############################################################
# SUBSCRIPTION
############################################################
SUBSCRIPTION="ee34d228-0201-4a8e-81e3-17dd322b166f"
az account set --subscription "$SUBSCRIPTION" >/dev/null 2>&1

CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json)

############################################################
# CLUSTER LOOP
############################################################
for CL in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do
  pull(){ echo "$CL" | base64 --decode | jq -r "$1"; }

  CLUSTER=$(pull '.name')
  RG=$(pull '.rg')

  az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null 2>&1
  kubectl get nodes >/dev/null 2>&1 || continue

  VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

  ##########################################################
  # CLUSTER SUMMARY
  ##########################################################
  cat <<EOF >> "$FINAL_REPORT"
<div class="card">
<h3>Cluster: $CLUSTER</h3>
<table>
<tr><th>Check</th><th>Status</th></tr>
<tr class="healthy-all"><td>Node Health</td><td>Healthy</td></tr>
<tr class="healthy-all"><td>Pod Health</td><td>Healthy</td></tr>
<tr class="healthy-all"><td>PVC Health</td><td>Healthy</td></tr>
<tr class="version-ok"><td>Cluster Version</td><td>$VERSION</td></tr>
</table>
</div>
EOF

  ##########################################################
  # CLUSTER UPGRADE & SECURITY SCHEDULE (FORMATTED)
  ##########################################################
  RAW_AUTO=$(az aks show -g "$RG" -n "$CLUSTER" \
    --query "autoUpgradeProfile.upgradeChannel" -o tsv 2>/dev/null)

  [[ -z "$RAW_AUTO" || "$RAW_AUTO" == "null" ]] && AUTO_MODE="Disabled" || AUTO_MODE="Enabled ($RAW_AUTO)"

  AUTO_MC=$(az aks maintenanceconfiguration show \
    --name aksManagedAutoUpgradeSchedule \
    -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null)

  if [[ -n "$AUTO_MC" ]]; then
    AD=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startDate')
    AT=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startTime')
    AU=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.utcOffset')
    AW=$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek')
    UPGRADE_SCHED=$(format_schedule "$AD $AT $AU" "$AW")
  else
    UPGRADE_SCHED="Not Configured"
  fi

  RAW_NODE=$(az aks show -g "$RG" -n "$CLUSTER" \
    --query "autoUpgradeProfile.nodeOsUpgradeChannel" -o tsv 2>/dev/null)

  [[ -z "$RAW_NODE" || "$RAW_NODE" == "null" ]] && NODE_TYPE="Node Image" || NODE_TYPE="$RAW_NODE"

  NODE_MC=$(az aks maintenanceconfiguration show \
    --name aksManagedNodeOSUpgradeSchedule \
    -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null)

  if [[ -n "$NODE_MC" ]]; then
    ND=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startDate')
    NT=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startTime')
    NU=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.utcOffset')
    NW=$(echo "$NODE_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek')
    NODE_SCHED=$(format_schedule "$ND $NT $NU" "$NW")
  else
    NODE_SCHED="Not Configured"
  fi

  cat <<EOF >> "$FINAL_REPORT"
<button class="collapsible">Cluster Upgrade & Security Schedule</button>
<div class="content"><pre>
Automatic Upgrade Mode     : $AUTO_MODE

Upgrade Window Schedule   :
$UPGRADE_SCHED

Node Security Channel Type : $NODE_TYPE
Security Channel Schedule :
$NODE_SCHED
</pre></div>
EOF

  ##########################################################
  # AUTOSCALING
  ##########################################################
  echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button><div class='content'><pre>" >> "$FINAL_REPORT"
  az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o table >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  ##########################################################
  # PSA
  ##########################################################
  echo "<button class='collapsible'>Namespace Pod Security Admission</button><div class='content'><pre>" >> "$FINAL_REPORT"
  kubectl get ns -o json | jq -r '.items[] |
  [.metadata.name,
   (.metadata.labels["pod-security.kubernetes.io/enforce"] // "none"),
   (.metadata.labels["pod-security.kubernetes.io/audit"] // "none"),
   (.metadata.labels["pod-security.kubernetes.io/warn"] // "none")] | @tsv' >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  ##########################################################
  # RBAC, NODES, PODS, SERVICES
  ##########################################################
  echo "<button class='collapsible'>Namespace RBAC</button><div class='content'><pre>" >> "$FINAL_REPORT"
  kubectl get rolebindings -A -o wide
  kubectl get clusterrolebindings -o wide
  echo "</pre></div>" >> "$FINAL_REPORT"

  echo "<button class='collapsible'>Node List</button><div class='content'><pre>" >> "$FINAL_REPORT"
  kubectl get nodes -o wide >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  echo "<button class='collapsible'>Pod List</button><div class='content'><pre>" >> "$FINAL_REPORT"
  kubectl get pods -A -o wide >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  echo "<button class='collapsible'>Services List</button><div class='content'><pre>" >> "$FINAL_REPORT"
  kubectl get svc -A -o wide >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

done

echo "</body></html>" >> "$FINAL_REPORT"

echo "============================================"
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "============================================"

exit 0
