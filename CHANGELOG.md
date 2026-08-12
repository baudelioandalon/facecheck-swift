# Cambios

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y
el versionado es [semántico](https://semver.org/lang/es/).

Una versión publicada en CocoaPods trunk es permanente. Los tags de git podrían
moverse, pero no se mueven: quien fijó una versión con Swift Package Manager
espera que siga significando lo mismo.

## [0.1.0] — 2026-08-12

Primera publicación. Port nativo de Swift del SDK de Kotlin Multiplatform, con
las mismas pruebas de comportamiento portadas desde `facecheck-kmp`.

### Agregado

- `FaceCheck.initialize(_:)`, `enroll(email:camera:…)` y `verify(email:camera:…)`,
  con `async`/`await` en el modo de lenguaje Swift 6.
- Captura con `AVFoundation` y detección de rostro con `Vision`: ángulos de la
  cabeza, apertura de ojos, nitidez y brillo.
- Máquina de retos de vida con plan aleatorio, equivalente a la de Kotlin.
- `LivenessState` con `instructionEs` y `progress` para pintar la UI sin
  escribir un `switch`, y `LivenessStateModel` para SwiftUI.
- Cliente HTTP sobre `URLSession`, sin dependencias externas, con reintentos y
  cuerpo `multipart/form-data` construido a mano.
- Redacción automática de llaves de API y correos en los registros.

### Notas

- El SDK no firma grants de enrolamiento. Los firma tu backend; el secreto no
  debe llegar al dispositivo.
- No incluye modelos, umbrales ni lógica de comparación: eso vive en el
  servidor.
- El anti-spoofing pasivo no es funcional y los retos de vida no son un control
  de seguridad. Ver las limitaciones en el README.

[0.1.0]: https://github.com/baudelioandalon/facecheck-swift/releases/tag/0.1.0
