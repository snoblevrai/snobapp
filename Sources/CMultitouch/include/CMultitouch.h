#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdbool.h>

/// Appelé à chaque trame tactile (thread MultitouchSupport, pas le thread principal).
/// - fingerCount : nombre de contacts sur la surface
/// - sumX / sumY : somme des positions normalisées (0…1) des `positionLimit` premiers contacts
typedef void (*CSTouchFrameHandler)(int fingerCount, float sumX, float sumY);

/// Charge MultitouchSupport.framework. Renvoie false si le framework ou un symbole manque.
bool CSMultitouchLoad(void);

/// Enregistre le gestionnaire Swift.
void CSMultitouchSetHandler(CSTouchFrameHandler handler);

/// Nombre de doigts dont on additionne les positions (réglage « doigts »).
void CSMultitouchSetPositionLimit(int limit);

/// Démarre l'écoute de tous les appareils multitouch présents. Renvoie le nombre d'appareils.
int CSMultitouchStart(void);

/// Arrête l'écoute et libère les appareils.
void CSMultitouchStop(void);

#endif
