#!/bin/bash
# Disable exit-on-error globally (important for GitHub Actions)
set +e

export AZURE_AKS_DISABLE_AUTO_VERSION_CHECK=true
export AZURE_CONFIG_DIR="$HOME/.azure"

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"
FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################################
# FORMAT DATE EXACTLY LIKE AZURE PORTAL
############################################################
format_schedule() {
  local start="$1"
  local freq="$2"
  local dow="$3"

  if [[ -z "$start" || "$start" == "null" ]]; then
    echo "Not Configured"
    return
  fi

  if formatted=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
    formatted="${formatted/%+0000/+00:00}"
  else
    formatted="$start"
  fi

  if [[ -n "$freq" && -n "$dow" ]]; then
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
.card {
  background:white; padding:20px; margin-bottom:35px;
  border-radius:12px; box-shadow:0 4px 12px rgba(0,0,0,0.08);
}
table {
  width:100%; border-collapse:collapse; margin-top:15px;
  border-radius:12px; overflow:hidden; font-size:15px;
}
th { background:#2c3e50; color:white; padding:12px; text-align:left; }
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
  background:#2d3436; color:#dfe6e9; padding:10px;
  border-radius:6px; overflow-x:auto;
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

CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json 2>/dev/null)

############################################################
# CLUSTER LOOP
############################################################
for CL in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do
  pull(){ echo "$CL" | base64 --decode | jq -r "$1"; }

  CLUSTER=$(pull '.name')
  RG=$(pull '.rg')

  echo "[INFO] Processing $CLUSTER"

  az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null 2>&1
  kubectl get nodes >/dev/null 2>&1 || continue

  VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

  NODE_ERR=$(kubectl get nodes --no-headers | awk '$2!="Ready"')
  POD_ERR=$(kubectl get pods -A --no-headers | awk '$4=="CrashLoopBackOff"')
  PVC_ERR=$(kubectl get pvc -A 2>/dev/null | grep -i failed)

  [[ -z "$NODE_ERR" ]] && NC="healthy-all" || NC="bad"
  [[ -z "$POD_ERR"  ]] && PC="healthy-all" || PC="bad"
  [[ -z "$PVC_ERR"  ]] && PVC="healthy-all" || PVC="bad"

cat <<EOF >> "$FINAL_REPORT"
<div class="card">
<h3>Cluster: $CLUSTER</h3>
<table>
<tr><th>Check</th><th>Status</th></tr>
<tr class="$NC"><td>Node Health</td><td>Healthy</td></tr>
<tr class="$PC"><td>Pod Health</td><td>Healthy</td></tr>
<tr class="$PVC"><td>PVC Health</td><td>Healthy</td></tr>
<tr class="version-ok"><td>Cluster Version</td><td>$VERSION</td></tr>
</table>
</div>
EOF

############################################################
# NODE LIST
############################################################
echo "<button class='collapsible'>Node List</button><div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get nodes -o wide 2>/dev/null >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# POD LIST
############################################################
echo "<button class='collapsible'>Pod List</button><div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get pods -A -o wide 2>/dev/null >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

############################################################
# SERVICES
############################################################
echo "<button class='collapsible'>Services List</button><div class='content'><pre>" >> "$FINAL_REPORT"
kubectl get svc -A -o wide 2>/dev/null >> "$FINAL_REPORT"
echo "</pre></div>" >> "$FINAL_REPORT"

done

echo "</body></html>" >> "$FINAL_REPORT"

echo "===================================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "===================================================="

exit 0
