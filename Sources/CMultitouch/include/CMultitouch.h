#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdbool.h>

/// Appelé uniquement quand le nombre de doigts change (thread MultitouchSupport).
/// Le trackpad envoie ~100 trames/s dès qu'un doigt bouge : le filtrage se fait en C pour ne
/// remonter en Swift que les transitions (quelques appels par geste).
/// - fingerCount : nouveau nombre de contacts
/// - sumX / sumY : somme des positions normalisées des `fingers` premiers contacts (si le
///   nombre de doigts correspond, sinon 0)
/// - lastX / lastY : dernière somme vue tant que le nombre de doigts correspondait
typedef void (*CSTouchFrameHandler)(int fingerCount, float sumX, float sumY, float lastX, float lastY);

/// Paramètres du filtre : actif, nombre de doigts, « accepter plus de doigts ».
void CSMultitouchConfigure(bool enabled, int fingers, bool allowMore);

/// Charge MultitouchSupport.framework. Renvoie false si le framework ou un symbole manque.
bool CSMultitouchLoad(void);

/// Enregistre le gestionnaire Swift.
void CSMultitouchSetHandler(CSTouchFrameHandler handler);

/// Démarre l'écoute de tous les appareils multitouch présents. Renvoie le nombre d'appareils.
int CSMultitouchStart(void);

/// Arrête l'écoute et libère les appareils.
void CSMultitouchStop(void);

#endif
