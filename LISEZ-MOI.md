# Touch Bar Control

Une seule app rassemble les commandes Spotify et le réglage de luminosité de la Touch Bar. Le logo Spotify est l’icône officielle, fournie comme ressource SVG locale.

Extension Spicetify + compagnon macOS natif, sans BetterTouchTool, abonnement ni compte développeur Spotify.

## Utilisation

Lance **Spotify Touch Bar.app** et Spotify. Le menu **♪** de la barre des menus permet d’afficher/masquer la Touch Bar et de quitter le compagnon. Fermer le panneau laisse le compagnon actif.

- **⏮ / ▶ ou ⏸ / ⏭** : morceau précédent, lecture/pause, suivant.
- **Pochette + titre et artiste** sur deux lignes.
- **Progression verte** toujours visible, avec temps écoulé et temps restant. Relâche pour appliquer.
- **Menu ♪ ou panneau** : favoris, aléatoire et répétition (désactivée → tout → un titre).
- Dans le panneau, le vert indique un favori, l’aléatoire ou la répétition activés.
- Le bouton de fermeture système rend la Touch Bar habituelle. Pour revenir : menu ♪ → Afficher la Touch Bar.

Le compagnon doit rester ouvert. Quand Spotify joue sur le Mac, la Touch Bar s’affiche automatiquement ; elle se masque lorsque la lecture s’arrête. Sa fenêtre contient aussi le curseur de luminosité de la Touch Bar, avec maintien optionnel, reconnexion et restauration du niveau de départ. Aucun démarrage automatique n’est ajouté. Pour démarrer avec ta session, tu peux ajouter l’application dans Réglages Système → Général → Ouverture.

La case **Synchroniser avec la luminosité de l’écran principal** est activée par défaut. Elle lit la luminosité de l’écran intégré et applique 80 % de ce niveau à la Touch Bar chaque seconde, car l’OLED paraît plus lumineux à niveau numérique égal. Les appels au service macOS de luminosité sont effectués hors du thread d’interface, afin de garder l’app réactive.

La lecture commencée sur un téléphone nécessite une liaison Spotify Web API. Elle utilise OAuth Authorization Code avec PKCE et le scope `user-read-playback-state`; aucun mot de passe ni secret client ne doit être enregistré. Le Client ID de l’application Spotify et l’URI de redirection doivent être configurés avant d’activer cette option.

Le Client ID fourni a été intégré et le compte a été lié avec succès pendant la vérification. Le compagnon interroge l’état Spotify toutes les cinq secondes ; il peut donc afficher le morceau lu sur un téléphone ou un autre appareil Spotify Connect même si l’application Spotify du Mac est fermée. Le jeton d’accès et le jeton de renouvellement sont conservés dans le trousseau macOS. Le bouton **Délier mon compte Spotify** efface ces jetons.

Les réponses réseau Spotify sont réexpédiées vers le thread principal avant toute mise à jour AppKit. Cela évite le crash observé lors du passage à une lecture distante. Fermer la fenêtre ne quitte pas le processus : l’app reste dans la barre des menus et continue la synchronisation.

## Installation et désactivation

Sur ce Mac, l’extension a été activée et le compagnon compilé pour Apple Silicon. Pour réinstaller : double-clique **Installer.command**. Le script conserve une sauvegarde datée de la configuration dans `backup/`, ajoute uniquement cette extension et applique Spicetify. Spotify peut redémarrer.

**Desinstaller.command** désactive uniquement cette extension et réapplique Spicetify ; quitte aussi le compagnon via son menu ♪. Le dossier et les sauvegardes restent disponibles.

Le programme est signé localement, pas notarialisé pour une distribution publique. Pour un autre Mac, copie les sources et scripts, puis lance `build.command` avec les outils de développement Apple installés. Supprime la copie de `pairing.txt` avant une nouvelle installation sur un autre Mac pour créer une nouvelle association. Ne partage pas ton fichier d’association ni tes sauvegardes de configuration.

## Fonctionnement

L’extension transmet l’état du lecteur au compagnon toutes les 500 ms et reçoit les commandes dans la réponse. Le serveur écoute exclusivement sur `127.0.0.1:43821`. Un jeton aléatoire local de 256 bits associe les deux composants ; aucun mot de passe ou jeton Spotify n’est utilisé. Les origines web sont limitées à celles du client Spotify. Les commandes expirent après trois secondes et ne sont pas rejouées après un échec réseau. Une progression demandée pour un autre morceau est ignorée.

La reconnexion est automatique (jusqu’à cinq secondes entre tentatives). Après quatre secondes sans réponse du lecteur, les commandes sont désactivées. Les favoris, aléatoire, répétition ou la progression peuvent être limités par le contenu ou l’appareil Spotify Connect actif.

## Limites et dépannage

L’affichage global utilise l’API privée macOS `presentSystemModalTouchBar:systemTrayItemIdentifier:`. Elle peut changer avec macOS et n’est pas adaptée à une publication App Store. Le panneau garde aussi une Touch Bar AppKit standard pour les systèmes où l’affichage global n’est pas disponible. La présence visuelle et le confort des gestes sur la Touch Bar physique restent à confirmer par l’utilisateur.

Si le panneau indique « Spotify déconnecté », ouvre Spotify et sélectionne un morceau. Vérifie que le compagnon est ouvert et qu’aucun autre programme n’utilise le port 43821. Après une mise à jour Spotify/Spicetify, une réapplication ou une adaptation de l’extension peut être nécessaire.

## Vérifications effectuées

- Compilation Swift/Objective-C et lancement du compagnon sur ce Mac.
- Connexion réelle à Spotify, réception du titre et de l’artiste.
- Commande pause et changement d’état de favori vérifiés ; favori remis à son état initial.
- Rejet des requêtes sans jeton et des origines non autorisées ; prévol CORS Spotify accepté.
- Tests JavaScript : commandes, état, limites du volume, progression obsolète et fin de morceau, injection unique, reconnexion.

Tests reproductibles avec Node.js : `node tests/extension.test.cjs`.

## Sources techniques

- [API Player Spicetify](https://spicetify.app/docs/development/api-wrapper/methods/player)
- [NSTouchBar — Apple](https://developer.apple.com/documentation/appkit/nstouchbar)
- [Exemple de l’API privée — touch-baer](https://github.com/a2/touch-baer/blob/master/TouchBarTest/AppDelegate.m)
- [Backend de luminosité TouchBarFloor](https://github.com/volpierre/TouchBarFloor) et TouchBarController, sous licence MIT ; mentions complètes dans `THIRD-PARTY-LICENSES.txt`.

Les pochettes sont chargées depuis le CDN Spotify `i.scdn.co`, uniquement en HTTPS. Le rendu de démonstration `apercu.png` utilise un titre fictif pour la prévisualisation, avec une icône de remplacement pour la pochette.

## Correction de la progression

La progression utilise désormais le même calcul que le lecteur Spotify installé : position de référence, horodatage, vitesse de lecture, pause et mise en mémoire tampon. La durée et la position proviennent du même état. Le calcul historique de `Spicetify.Player.getProgress()` ne sert que de repli lorsque cet état est indisponible. Tests ajoutés pour la lecture normale, la vitesse, le chargement, la pause, la recherche et le changement de titre.

## Correction du remplissage visuel

Les curseurs utilisent un contrôle dessiné intégralement, sans le rendu automatique NSSlider de la Touch Bar. Le remplissage, le point blanc et la position tactile emploient les mêmes bornes. Les gestes directs, clics, déplacements et commandes d’accessibilité sont gérés explicitement. 28 vérifications de rendu pixel ont validé les fractions 0–100 %, quatre largeurs et le retour en arrière (`tests/slider-render.swift`). Les gestes sur le matériel réel restent à confirmer.

## Largeur réelle de la Touch Bar

La photo du matériel a révélé que la vue de 1000 points était coupée par les commandes système, donnant une fausse impression de remplissage. Le compagnon et son aperçu utilisent désormais une largeur fixe de 640 points. Le temps restant doit rester visible avant les commandes macOS. Un test de disposition complète vérifie que tous les éléments tiennent dans cette largeur et ne se chevauchent pas.
