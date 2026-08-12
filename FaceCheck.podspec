Pod::Spec.new do |s|
  s.name    = 'FaceCheck'
  # Una sola fuente de verdad para la version. Un paquete de Swift no lleva
  # numero de version en ningun lado —- para SPM la version ES el tag de git—
  # asi que sin este archivo la version viviria duplicada entre el tag, el
  # podspec y el CHANGELOG, y tarde o temprano dejarian de coincidir.
  s.version = File.read(File.join(__dir__, 'VERSION')).strip
  s.summary = 'SDK de FaceCheck para verificacion facial con liveness activo en iOS.'

  s.description = <<~DESC
    Captura un rostro con liveness activo (retos de movimiento) y lo envia al
    backend de FaceCheck para enrolar o verificar.

    El emparejamiento de rostros ocurre en el servidor: este SDK no incluye
    modelos, umbrales ni logica de comparacion, y nunca firma credenciales.
  DESC

  s.homepage = 'https://facecheck.borealnetwork.org'
  s.license  = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author   = { 'Boreal Network' => 'soporte@borealnetwork.org' }

  s.source = {
    :git => 'https://github.com/baudelioandalon/facecheck-swift.git',
    :tag => s.version.to_s,
  }

  s.ios.deployment_target = '15.0'
  # Solo 6.0: las fuentes se compilan en el modo de lenguaje Swift 6 (vease
  # Package.swift). Anunciar 5.9 haria que CocoaPods compilara el pod en modo
  # Swift 5, donde las carreras de datos vuelven a ser advertencias y el SDK
  # dejaria de estar verificado precisamente donde promete estarlo.
  s.swift_versions = ['6.0']

  s.source_files = 'Sources/FaceCheck/**/*.swift'

  s.frameworks = 'AVFoundation', 'Vision', 'CoreImage', 'UIKit'

  # La camara es el proposito del SDK: sin esta clave la app se cae en cuanto
  # empieza una sesion, y el fallo aparece en produccion, no al integrar.
  s.info_plist = {
    'NSCameraUsageDescription' => 'Se usa la camara para verificar tu identidad.',
  }
end
