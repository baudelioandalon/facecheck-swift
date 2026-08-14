# Cambios

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y
el versionado es [semántico](https://semver.org/lang/es/).

Una versión publicada en CocoaPods trunk es permanente. Los tags de git podrían
moverse, pero no se mueven: quien fijó una versión con Swift Package Manager
espera que siga significando lo mismo.

## [Sin publicar]

Nada todavía.

## [1.0.0] — 2026-08-13

Candidato preparado localmente; todavía no fue publicado ni etiquetado.

### Cambiado

- **Ruptura de API:** `FaceCheck.enroll` y `FaceCheck.verify` ahora requieren
  `subjectId:`; el campo multipart `email` fue eliminado.
- Se reemplazaron `MISSING_EMAIL` e `INVALID_EMAIL` por
  `MISSING_SUBJECT_ID` e `INVALID_SUBJECT_ID`.
- No existen sobrecargas, alias ni compatibilidad para `email:`: las
  integraciones deben migrar de forma explícita.

### Agregado

- `FaceCheckSubjectId.generate(apiKey:)` crea IDs opacos con una huella SHA-256
  codificada en Base32 y 128 bits aleatorios de `SecRandomCopyBytes`; el formato
  exacto es `sub_<huella>_<aleatorio>`
  (`^sub_[A-Z2-7]{10}_[A-Za-z0-9_-]{22}$`), con los primeros 10 caracteres
  Base32 de SHA-256 y 16 bytes en Base64URL sin relleno. No expone la llave.

### Orden de lanzamiento

1. Desplegar Functions TypeScript y Python con el contrato `subjectId`.
2. Validar `/enroll` y `/verify` en un entorno autorizado con datos sintéticos.
3. Publicar KMP, Swift, Android y CLI 1.0.0.
4. Desplegar el portal con la documentación y el directorio compatibles.

Este orden es una lista de ejecución; este cambio no despliega ni publica nada.

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

[Sin publicar]: https://github.com/baudelioandalon/facecheck-swift/compare/1.0.0...HEAD
[1.0.0]: https://github.com/baudelioandalon/facecheck-swift/releases/tag/1.0.0
[0.1.0]: https://github.com/baudelioandalon/facecheck-swift/releases/tag/0.1.0
