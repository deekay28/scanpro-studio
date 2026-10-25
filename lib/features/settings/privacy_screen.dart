import 'package:flutter/material.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget h(String s) => Padding(padding: const EdgeInsets.only(top: 20, bottom: 6), child: Text(s, style: t.titleMedium));
    Widget p(String s) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(s, style: t.bodyMedium));
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & permissions')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        h('Offline by design'),
        p('ScanPro Studio has no account, no cloud service and no analytics. The release app does not even request the Internet permission, so it cannot upload your documents.'),
        p('Scanning, filters, edge detection, OCR, face detection, background replacement, PDF creation and printing all run on this device.'),
        p('Exception: the "Smart scan" option uses Google\'s on-device document scanner, which runs inside Google Play services. Google Play services may download or update that scanner module; your images are processed on the device.'),
        h('Where documents are stored'),
        p('Documents live in the app\'s private storage, which other apps cannot read. Originals are kept unchanged next to processed pages. Processed images and exports do not contain camera EXIF data such as GPS location.'),
        p('Files leave the app only when you choose Share, Save to device (you pick the folder through Android\'s file picker), Print or Backup.'),
        h('Permissions'),
        p('• Camera – only for the Pro camera and portrait capture. Requested the first time you use it.'),
        p('• Photos – not requested. Images are chosen with the Android Photo Picker, which only gives the app the pictures you select.'),
        p('• Files – not requested. PDFs and backups are opened and saved through the system document picker.'),
        p('• Biometrics – only if you enable App lock or the vault. Fingerprint/face data never reaches the app; Android only reports success or failure.'),
        h('PDF password vs. app encryption'),
        p('A password-protected PDF is encrypted inside the file (AES-256). Anyone you send it to needs the password. The app does not remember PDF passwords.'),
        p('The private vault encrypts documents inside the app with a key held in Android\'s secure keystore. It protects documents at rest on this device; it does not affect files you export.'),
        p('App lock stops other people from opening the app on an unlocked phone. Android already encrypts the device storage when a screen lock is set.'),
        h('Deleting'),
        p('Deleted documents go to Recently deleted and are removed after the retention period, or immediately when you empty it. Phones use flash storage that cannot guarantee secure erasure, so the app does not claim to shred files.'),
        h('OCR and AI features'),
        p('OCR results are suggestions and can contain mistakes; uncertain lines are highlighted for review. Document type, names, dates and amounts are detected with simple on-device rules, not cloud AI. No document is ever sent to an AI service.'),
      ]),
    );
  }
}
