#!/usr/bin/env bash
# Crea en Microsoft Entra ID (Azure): registro de la API/BFF (scope + App roles), registro de la SPA,
# 3 usuarios de prueba y sus asignaciones de rol. REQUIERE `az login` con permisos de administrador del tenant.
# NO fue ejecutado por quien lo generó: revísalo y úsalo como apoyo; el checklist del portal está en docs/DESPLIEGUE-AWS-AZURE.md.
#
# Uso:  ./setup-entra.sh <dominio-del-tenant> <url-front-https>
#   ej: ./setup-entra.sh midominio.onmicrosoft.com https://d1234abcd.cloudfront.net
set -euo pipefail
DOMAIN="${1:?dominio del tenant (ej. midominio.onmicrosoft.com)}"
FRONT_URL="${2:-}"
PASS="${TEST_USER_PASSWORD:-Cambiar-Esta-Clave-123!}"

TENANT_ID=$(az account show --query tenantId -o tsv)
SCOPE_ID=$(python3 -c 'import uuid;print(uuid.uuid4())')
R_ADMIN=$(python3 -c 'import uuid;print(uuid.uuid4())')
R_RECEP=$(python3 -c 'import uuid;print(uuid.uuid4())')
R_PAC=$(python3 -c 'import uuid;print(uuid.uuid4())')

echo "== 1) Registro de la API (BFF) =="
API_APP_ID=$(az ad app create --display-name "vidasalud-api" --sign-in-audience AzureADMyOrg --query appId -o tsv)
API_OBJ_ID=$(az ad app show --id "$API_APP_ID" --query id -o tsv)
az ad sp create --id "$API_APP_ID" >/dev/null
API_SP_ID=$(az ad sp show --id "$API_APP_ID" --query id -o tsv)

cat > /tmp/api-patch.json <<JSON
{
  "identifierUris": ["api://$API_APP_ID"],
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [{
      "id": "$SCOPE_ID", "value": "access_as_user", "type": "User", "isEnabled": true,
      "adminConsentDisplayName": "Acceder a VidaSalud", "adminConsentDescription": "Permite a la SPA llamar a la API en nombre del usuario",
      "userConsentDisplayName": "Acceder a VidaSalud", "userConsentDescription": "Permite a la aplicación llamar a la API en tu nombre"
    }]
  },
  "appRoles": [
    {"id":"$R_ADMIN","value":"Admin","displayName":"Admin","description":"Administrador","allowedMemberTypes":["User"],"isEnabled":true},
    {"id":"$R_RECEP","value":"Recepcionista","displayName":"Recepcionista","description":"Recepción","allowedMemberTypes":["User"],"isEnabled":true},
    {"id":"$R_PAC","value":"Paciente","displayName":"Paciente","description":"Paciente","allowedMemberTypes":["User"],"isEnabled":true}
  ]
}
JSON
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$API_OBJ_ID" \
  --headers "Content-Type=application/json" --body @/tmp/api-patch.json

echo "== 2) Registro de la SPA =="
REDIRECTS='"http://localhost:4200"'
[ -n "$FRONT_URL" ] && REDIRECTS="$REDIRECTS,\"$FRONT_URL\""
SPA_APP_ID=$(az ad app create --display-name "vidasalud-spa" --sign-in-audience AzureADMyOrg --query appId -o tsv)
SPA_OBJ_ID=$(az ad app show --id "$SPA_APP_ID" --query id -o tsv)
az ad sp create --id "$SPA_APP_ID" >/dev/null
cat > /tmp/spa-patch.json <<JSON
{
  "spa": {"redirectUris": [$REDIRECTS]},
  "requiredResourceAccess": [{"resourceAppId": "$API_APP_ID", "resourceAccess": [{"id": "$SCOPE_ID", "type": "Scope"}]}]
}
JSON
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$SPA_OBJ_ID" \
  --headers "Content-Type=application/json" --body @/tmp/spa-patch.json

# Pre-autoriza la SPA para el scope (evita pantalla de consentimiento)
cat > /tmp/preauth.json <<JSON
{"api": {"requestedAccessTokenVersion": 2, "preAuthorizedApplications": [{"appId": "$SPA_APP_ID", "delegatedPermissionIds": ["$SCOPE_ID"]}]}}
JSON
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$API_OBJ_ID" \
  --headers "Content-Type=application/json" --body @/tmp/preauth.json

echo "== 3) Usuarios de prueba y roles =="
assign() { # upn nombre roleId
  az ad user create --display-name "$2" --user-principal-name "$1" --password "$PASS" --force-change-password-next-sign-in false >/dev/null
  UID_=$(az ad user show --id "$1" --query id -o tsv)
  az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$API_SP_ID/appRoleAssignedTo" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$UID_\",\"resourceId\":\"$API_SP_ID\",\"appRoleId\":\"$3\"}" >/dev/null
  echo "  $1 -> rol asignado"
}
assign "admin.vidasalud@$DOMAIN"  "Admin VidaSalud"          "$R_ADMIN"
assign "recep.vidasalud@$DOMAIN"  "Recepcionista VidaSalud"  "$R_RECEP"
assign "paciente.vidasalud@$DOMAIN" "Paciente VidaSalud"     "$R_PAC"

cat <<OUT

================ VALORES PARA .env (raíz del proyecto) ================
ENTRA_TENANT_ID=$TENANT_ID
ENTRA_SPA_CLIENT_ID=$SPA_APP_ID
ENTRA_API_CLIENT_ID=$API_APP_ID
Contraseña de los usuarios de prueba: $PASS  (cámbiala)
OUT
