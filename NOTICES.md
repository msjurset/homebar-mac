# Third-Party Notices

HomeBar includes the following third-party components. Each retains its own license; the terms below are reproduced where required.

## Material Design Icons

The bundled `Resources/materialdesignicons.ttf` font and `Resources/mdi-map.json` codepoint table are from the [Material Design Icons](https://pictogrammers.com/library/mdi/) project.

License: [Apache License 2.0](https://github.com/Templarian/MaterialDesign/blob/master/LICENSE)

> Material Design Icons - Community
> Copyright (c) Pictogrammers and contributors

## Sparkle

HomeBar uses the [Sparkle](https://sparkle-project.org) framework for in-app software updates.

License: [MIT License](https://github.com/sparkle-project/Sparkle/blob/master/LICENSE)

> Copyright (c) 2006-2013 Andy Matuschak.
> Copyright (c) 2009-2013 Elgato Systems GmbH.
> Copyright (c) 2011-2014 Kornel Lesiński.
> Copyright (c) 2015-2017 Mayur Pawashe.
> Copyright (c) 2014 C-Command Software.
> Copyright (c) 2014 Federico Ciardi.

Sparkle bundles additional components with their own licenses (bspatch, ed25519, etc.) — see the upstream [LICENSE](https://github.com/sparkle-project/Sparkle/blob/master/LICENSE) file for the full list.

## Home Assistant

HomeBar talks to a [Home Assistant](https://www.home-assistant.io) instance you operate. Home Assistant itself is not bundled with HomeBar; it is accessed at runtime over the WebSocket and REST APIs you already have configured.
