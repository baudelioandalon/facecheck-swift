# FaceCheck para iOS

SDK nativo de Swift para [FaceCheck](https://facecheck.borealnetwork.org):
enrola un rostro de referencia, verifica una selfie contra él o contra el
retrato de una INE, y guía la captura con retos de movimiento.

```swift
try FaceCheck.initialize(FaceCheckConfig(apiKey: "lk_test_…", baseUrl: "…"))
let resultado = try await FaceCheck.verify(subjectId: "person_01", camera: camara)
print(resultado.verified)
```

## Qué hace y qué no

El SDK **captura**. Abre la cámara frontal, conduce los retos de vida, elige el
mejor cuadro y lo sube por HTTPS.

La comparación de rostros ocurre en el **servidor**. Aquí no hay modelos, ni
embeddings, ni umbrales: el paquete pesa lo que pesa porque no lleva nada de
eso. Tampoco firma credenciales — los grants de enrolamiento los firma tu
backend con un secreto que nunca debe llegar al dispositivo.

## Instalación

### Swift Package Manager

Swift Package Manager no tiene registro central: la versión **es** un tag de
git, así que se apunta al repositorio directamente.

```swift
dependencies: [
    .package(url: "https://github.com/baudelioandalon/facecheck-swift.git", from: "1.0.0")
]
```

Desde Xcode: **File › Add Package Dependencies** y pega esa URL.

### CocoaPods

```ruby
pod 'FaceCheck', '~> 1.0.0'
```

### Requisitos

| | |
|---|---|
| iOS | 15.0 o mayor |
| Swift | 6.0 (el SDK compila en modo de lenguaje Swift 6) |
| Dependencias | ninguna |

Tu app necesita declarar el uso de la cámara en `Info.plist`, o se cerrará al
empezar una sesión:

```xml
<key>NSCameraUsageDescription</key>
<string>Se usa la cámara para verificar tu identidad.</string>
```

## Uso

### Inicializar

Una sola vez, al arrancar la app. Llamarlo otra vez con una configuración
distinta lanza en lugar de reapuntar el SDK en silencio: dos configuraciones en
un proceso son dos llaves, y por tanto dos inquilinos o dos modos.

```swift
import FaceCheck

let config = try FaceCheckConfig(
    apiKey: "lk_test_tu_llave",
    baseUrl: "https://us-central1-facecheck-mx.cloudfunctions.net"
)
try FaceCheck.initialize(config)
```

El prefijo de la llave decide el modo: `lk_test_` es sandbox y `lk_live_` es
producción. Los datos de los dos modos están separados.

### Enrolar

```swift
let camara = makeCameraController(viewController: self)
let subjectId = try FaceCheckSubjectId.generate(apiKey: config.apiKey)

let resultado = try await FaceCheck.enroll(
    subjectId: subjectId,
    camera: camara,
    grant: grantDeTuBackend   // obligatorio con lk_live_
)

print(resultado.enrolled)
```

El generador produce exactamente `sub_<huella>_<aleatorio>`: 10 caracteres
Base32 de SHA-256 de la llave y 16 bytes criptográficamente seguros como 22
caracteres Base64URL sin relleno. Guarda el ID opaco asociado a la cuenta de tu
producto y reutilízalo al verificar.

`grant` es un token corto que **tu backend** firma. Con llaves `lk_live_` es
obligatorio: sin él, cualquiera con la llave de la app podría enrolar su cara
contra el ID de persona de otra persona.

Para comparar después contra una INE, súbela en el mismo enrolamiento:

```swift
try await FaceCheck.enroll(subjectId: subjectId, camera: camara, grant: grant, ine: jpegDeLaINE)
```

### Verificar

```swift
let resultado = try await FaceCheck.verify(subjectId: "person_01", camera: camara)

if resultado.verified {
    // adelante
} else {
    // no coincide; resultado trae el motivo
}
```

Un rostro que no coincide **no es un error**: regresa como `VerifyResult` con
`verified == false`. Los errores son la sesión fallida o la petición rechazada.

Para comparar contra la INE en lugar del enrolamiento:

```swift
try await FaceCheck.verify(subjectId: subjectId, camera: camara, compareWith: .ine)
```

### Pintar la UI

La sesión emite estados que describen qué debe hacer la persona. Crea la
máquina antes de empezar para poder suscribirte **antes** del primer cuadro, y
que la pantalla no arranque vacía:

```swift
let maquina = try FaceCheck.makeChallengeMachine()

Task {
    for await estado in maquina.state.values {
        etiqueta.text = estado.instructionEs
        barra.progress = estado.progress
    }
}

let resultado = try await FaceCheck.verify(subjectId: subjectId, camera: camara, machine: maquina)
```

`instructionEs` cubre los seis estados —`idle`, `positioning`, `challengeActive`,
`capturing`, `done` y `failed`— con la línea que le toca ver a la persona. Si
prefieres tu propio texto puedes hacer `switch` sobre el estado, pero entonces
te toca actualizarlo cuando el SDK agregue estados.

En SwiftUI, `LivenessStateModel` hace lo mismo como `ObservableObject`:

```swift
@StateObject private var modelo = LivenessStateModel(maquina.state)
```

## Limitaciones

Esto es lo que el sistema **no** hace. Vale la pena leerlo antes de decidir
dónde ponerlo:

- **No hay anti-spoofing pasivo funcional.** `spoofScore` viaja siempre en
  `null`. Una foto impresa o una pantalla pueden pasar la comparación.
- **Los retos de vida son ayuda de captura, no un control de seguridad.**
  Corren en el dispositivo y el backend no los verifica: `livenessEnforced`
  siempre es `false`. Sirven para obtener un cuadro nítido y frontal, no para
  demostrar que hay una persona viva.
- **El canal INE es experimental.** Su umbral se calibró con una sola
  credencial real. Trátalo como señal, no como puerta.
- **No hay detección de deepfakes** ni certificación ISO/IEC 30107-3.

Los números medidos —EER de 1.83 % sobre 1,200 pares de LFW, umbrales de 0.60 y
0.64— están en [Umbrales y precisión](https://facecheck.borealnetwork.org/docs/umbrales).

## Documentación

- [Inicio rápido](https://facecheck.borealnetwork.org/docs)
- [Referencia del SDK](https://facecheck.borealnetwork.org/docs/sdk/referencia)
- [Retos de vida](https://facecheck.borealnetwork.org/docs/sdk/retos)
- [Grants de enrolamiento](https://facecheck.borealnetwork.org/docs/grants)
- [Errores comunes](https://facecheck.borealnetwork.org/docs/errores)

Para integrar desde la terminal —o para que lo haga un asistente de IA sin
navegador— existe el [CLI](https://facecheck.borealnetwork.org/docs/cli).

## Otras plataformas

| Plataforma | Paquete |
|---|---|
| Android | `org.borealnetwork:facecheck-android` |
| Android + iOS (KMP) | `org.borealnetwork:facecheck-kmp` |

## Licencia

Apache 2.0. Ver [LICENSE](LICENSE).
