#ifndef CSMC_H
#define CSMC_H

#include <stdbool.h>
#include <stdint.h>
#include "PowerUIBridge.h"

/// Accès bas niveau au System Management Controller (AppleSMC).
/// Lecture possible en utilisateur ; écriture réservée à root.

bool CSSMCOpen(void);
void CSSMCClose(void);

/// Lit une clé de 4 caractères. Renvoie le nombre d'octets lus (≤ 32), ou -1 si la clé n'existe pas.
int CSSMCRead(const char *key, uint8_t *bytes, uint32_t *dataType);

/// Écrit `size` octets dans une clé existante (la taille doit correspondre). Renvoie 0 si succès.
int CSSMCWrite(const char *key, const uint8_t *bytes, uint32_t size);

#endif
