#!/usr/bin/env bash
# Crea un API Gateway HTTP API con autorizador JWT (Microsoft Entra ID) delante del BFF en EC2.
# Requiere: aws cli v2 configurado. NO fue ejecutado por quien lo generó: verifícalo en tu cuenta.
#
# Uso: ./create-api-gateway.sh <EC2_PUBLIC_DNS_O_IP> <TENANT_ID> <API_CLIENT_ID> <FRONT_ORIGIN>
#  ej: ./create-api-gateway.sh ec2-1-2-3-4.compute-1.amazonaws.com <tenant> <api-app-id> https://d1234abcd.cloudfront.net
set -euo pipefail
EC2="${1:?EC2 host}"; TENANT="${2:?tenant id}"; API_CID="${3:?api client id}"; ORIGIN="${4:?origen del front}"
REGION="${AWS_REGION:-$(aws configure get region)}"
BFF="http://$EC2:8084"

API_ID=$(aws apigatewayv2 create-api --name vidasalud-api --protocol-type HTTP \
  --cors-configuration "AllowOrigins=$ORIGIN,http://localhost:4200,AllowMethods=GET,POST,PUT,DELETE,OPTIONS,AllowHeaders=authorization,content-type,MaxAge=3600" \
  --query ApiId --output text)

# Autorizador JWT: valida firma (JWKS de Entra), issuer y audience antes de llegar al BFF.
AUTH_ID=$(aws apigatewayv2 create-authorizer --api-id "$API_ID" --name entra-jwt --authorizer-type JWT \
  --identity-source '$request.header.Authorization' \
  --jwt-configuration "Audience=$API_CID,api://$API_CID,Issuer=https://login.microsoftonline.com/$TENANT/v2.0" \
  --query AuthorizerId --output text)

INT_PROXY=$(aws apigatewayv2 create-integration --api-id "$API_ID" --integration-type HTTP_PROXY \
  --integration-method ANY --integration-uri "$BFF/api/{proxy}" --payload-format-version 1.0 \
  --query IntegrationId --output text)
INT_HEALTH=$(aws apigatewayv2 create-integration --api-id "$API_ID" --integration-type HTTP_PROXY \
  --integration-method GET --integration-uri "$BFF/api/health" --payload-format-version 1.0 \
  --query IntegrationId --output text)

# Rutas protegidas
aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'ANY /api/{proxy+}' \
  --authorization-type JWT --authorizer-id "$AUTH_ID" --target "integrations/$INT_PROXY" >/dev/null
# Preflight CORS y health: sin autorización
aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'OPTIONS /api/{proxy+}' \
  --authorization-type NONE --target "integrations/$INT_PROXY" >/dev/null
aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'GET /api/health' \
  --authorization-type NONE --target "integrations/$INT_HEALTH" >/dev/null

aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
URL="https://$API_ID.execute-api.$REGION.amazonaws.com"
echo "API Gateway listo: $URL"
echo "Usa API_BASE_URL=$URL al construir el front. Prueba: curl $URL/api/health  y  curl -i $URL/api/appointments (debe dar 401)."
