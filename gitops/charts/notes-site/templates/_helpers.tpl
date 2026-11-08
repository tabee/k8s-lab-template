{{/* Check required values and common labels. */}}
{{- define "notes.check" -}}
{{- $_ := required "site.name is missing (gitops/sites.yaml)" .Values.site.name -}}
{{- $_ := required "site.host is missing (gitops/sites.yaml)" .Values.site.host -}}
{{- $_ := required "site.repo is missing (gitops/sites.yaml)" .Values.site.repo -}}
{{- if not (has .Values.site.auth (list "sso" "basic")) -}}
{{- fail (printf "site.auth must be sso or basic (gitops/sites.yaml), is: %v" .Values.site.auth) -}}
{{- end -}}
{{- end -}}
{{/* Content SSH port comes from the content URL, never from the k8s-lab source. */}}
{{- define "notes.contentPort" -}}
{{- $url := urlParse .Values.site.repo -}}
{{- if or (ne $url.scheme "ssh") (empty $url.hostname) -}}
{{- fail "site.repo must be an ssh:// URL with a host" -}}
{{- end -}}
{{- $port := default "22" (trimPrefix ":" (regexFind ":[0-9]+$" $url.host)) -}}
{{- if or (lt (int $port) 1) (gt (int $port) 65535) -}}
{{- fail "site.repo SSH port must be between 1 and 65535" -}}
{{- end -}}
{{- $port -}}
{{- end -}}
{{/* "true" when the site is behind Keycloak (oauth2-proxy), empty with basic. */}}
{{- define "notes.sso" -}}
{{- if eq .Values.site.auth "sso" -}}true{{- end -}}
{{- end -}}
{{- define "notes.proxyLabels" -}}
app.kubernetes.io/name: notes-oauth2-proxy
app.kubernetes.io/instance: {{ .Values.site.name }}
app.kubernetes.io/part-of: notes
{{- end -}}
{{- define "notes.proxySelector" -}}
app.kubernetes.io/name: notes-oauth2-proxy
app.kubernetes.io/instance: {{ .Values.site.name }}
{{- end -}}
{{- define "notes.labels" -}}
app.kubernetes.io/name: notes
app.kubernetes.io/instance: {{ .Values.site.name }}
app.kubernetes.io/part-of: notes
{{- end -}}
{{- define "notes.selector" -}}
app.kubernetes.io/name: notes
app.kubernetes.io/instance: {{ .Values.site.name }}
{{- end -}}
{{- define "notes.crdAnnotation" -}}
# CRD comes with the apps traefik and cert-manager (retry in the ApplicationSet).
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end -}}
