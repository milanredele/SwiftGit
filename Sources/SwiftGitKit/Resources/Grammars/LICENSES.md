# TextMate grammars

These grammars are bundled in compressed form (raw DEFLATE of the minified
JSON) and used by SwiftGit's TextMate highlighter for languages that have no
tree-sitter grammar in the app. They were taken from the `extensions/`
folder of [microsoft/vscode](https://github.com/microsoft/vscode)
(MIT License, Copyright (c) Microsoft Corporation), which converts them from
the upstream projects below. Each grammar keeps its upstream license.

| Grammar (scope) | Upstream | License |
|---|---|---|
| source.batchfile | https://github.com/mmims/language-batchfile | MIT |
| source.css.less | https://github.com/radium-v/Better-Less | MIT |
| source.css.scss, source.sassdoc | https://github.com/atom/language-sass | MIT |
| source.dart | https://github.com/dart-lang/dart-syntax-highlight | BSD 3-Clause |
| source.diff | https://github.com/textmate/diff.tmbundle | TextMate Bundle License |
| source.dockerfile | https://github.com/moby/moby (contrib/syntax) | Apache License 2.0 |
| source.groovy | https://github.com/textmate/groovy.tmbundle | TextMate Bundle License |
| text.html.basic, text.html.derivative | https://github.com/textmate/html.tmbundle | TextMate Bundle License |
| source.ini | https://github.com/textmate/ini.tmbundle | TextMate Bundle License |
| text.log | https://github.com/emilast/vscode-logfile-highlighter | MIT |
| source.lua | https://github.com/sumneko/lua.tmbundle | TextMate Bundle License |
| source.makefile | https://github.com/fadeevab/make.tmbundle | TextMate Bundle License |
| text.html.markdown | https://github.com/microsoft/vscode-markdown-tm-grammar (based on https://github.com/textmate/markdown.tmbundle) | MIT / TextMate Bundle License |
| source.objc | https://github.com/jeff-hykin/better-objc-syntax | MIT |
| source.perl | https://github.com/textmate/perl.tmbundle | TextMate Bundle License |
| source.php, text.html.php | https://github.com/KapitanOczywisty/language-php | MIT |
| source.powershell | https://github.com/PowerShell/EditorSyntax | MIT |
| source.r | https://github.com/REditorSupport/vscode-R-syntax | MIT |
| source.sql | https://github.com/microsoft/vscode-mssql | MIT |
| text.xml, text.xml.xsl | https://github.com/atom/language-xml | MIT |
| source.yaml, source.yaml.* | https://github.com/RedCMD/YAML-Syntax-Highlighter | MIT |

**TextMate Bundle License:** "Permission to copy, use, modify, sell and
distribute this software is granted. This software is provided "as is"
without express or implied warranty, and with no claim as to its suitability
for any purpose."

The full license texts are in the upstream repositories linked above.
