{
  "type": {{ toJson .Type }},
  "keyId": {{ toJson .KeyID }},
  "principals": [{{ range $i, $g := .Token.groups }}{{ if $i }},{{ end }}{{ toJson $g }}{{ end }}],
  "extensions": {{ toJson .Extensions }}
}
