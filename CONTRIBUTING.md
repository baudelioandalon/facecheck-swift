# Contribuir

## Compilar y probar

```bash
swift build
swift test
```

`Package.swift` declara `.macOS(.v12)` además de `.iOS(.v15)`, y eso merece una
explicación porque no significa que exista un producto para macOS. Sin esa
línea, `swift build` compila para el host con un piso de macOS 10.13 y falla en
`async/await` — no por el código, sino por SwiftPM. Con ella, la lógica pura
(máquina de retos, multipart, redacción del registro) se prueba en segundos sin
levantar un simulador. La capa de cámara vive bajo `#if canImport(UIKit)`, así
que una compilación para macOS simplemente no la incluye.

Para compilar de verdad lo que toca AVFoundation y Vision hace falta iOS:

```bash
xcodebuild -scheme FaceCheck -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### Tu Xcode compila más de lo que compila el de CI

Esto ya costó una publicación rota, así que vale la pena decirlo: el runner de
GitHub trae **Xcode 16.4 (Swift 6.0)** y tu Mac probablemente traiga uno más
nuevo. Swift 6.3 aceptó cosas que 6.0 rechaza, y el código que solo tú compilas
es código que ningún integrador con Xcode 16 puede usar.

Las dos que ya mordieron:

- `CIContext` es `Sendable` en el SDK de Xcode 26 y no en el de 16.4. De ahí el
  `nonisolated(unsafe)` en `JPEGEncoding`.
- Swift 6.0 exige `self.` explícito dentro de una closure que escapa, aunque
  haya `guard let self`. Swift 6.3 ya no.

Si tocas la capa de cámara, da por hecho que un `swift build` verde en tu
máquina no dice nada sobre CI. Empuja a una rama y deja que CI opine.

Antes de publicar, valida el podspec:

```bash
pod lib lint FaceCheck.podspec --allow-warnings --fail-fast
```

## Este paquete es un port, no una reescritura

El SDK de referencia es
[`facecheck-kmp`](https://github.com/baudelioandalon/facecheck-kmp). Las dos
librerías hablan con el mismo backend, así que un cambio de comportamiento aquí
no es una mejora local: es una divergencia.

Las pruebas de `Tests/FaceCheckTests` están portadas desde las de Kotlin y son
la definición operativa de ese comportamiento. Si vas a cambiar la máquina de
retos, los umbrales de captura o el cuerpo `multipart`, cambia primero la
librería de Kotlin y trae el cambio con su prueba.

Hay tres cosas que **no** pueden entrar en este paquete, y no por estilo:

1. **Firmar grants de enrolamiento.** El secreto de firma vive en el backend
   del integrador. Un SDK que lo lleve encima convierte cualquier app publicada
   en una copia de ese secreto.
2. **Umbrales de comparación, modelos o embeddings.** La decisión de si dos
   caras son la misma se toma en el servidor. Aquí no hay nada que ajustar.
3. **Dependencias externas.** El paquete no depende de nada, y eso es una
   propiedad, no una casualidad: un SDK de identidad que arrastra dependencias
   arrastra también sus vulnerabilidades a la app de quien lo integre.

## Estilo

- Comentarios en inglés; textos de cara al usuario en español.
- Los comentarios explican **por qué**, no qué. Si el código ya dice qué hace,
  el comentario sobra; si hubo una decisión no obvia, escríbela.
- Concurrencia estricta de Swift 6. Un `@unchecked Sendable` necesita, encima
  de la declaración, la razón por la que es correcto.

## Publicar

No publiques a mano. Sube el número en `VERSION` y empuja a `main`: el workflow
`Release` corre las pruebas, valida el podspec, crea el tag —que es la
publicación para Swift Package Manager— y sube a CocoaPods trunk si hay token.

Si la versión ya tiene tag, el workflow termina en verde sin hacer nada. Una
versión en trunk es permanente y no se puede reemplazar.
