#ifndef POWERUI_BRIDGE_H
#define POWERUI_BRIDGE_H

#include <stdbool.h>

/// Limite de charge native de macOS (Réglages Système › Batterie › Limite de charge).
bool CSNativeLimitSupported(void);
/// Remplit `values` avec les paliers acceptés (ex. 80, 85, 90, 95, 100). Renvoie leur nombre.
int CSNativeLimitAvailable(int *values, int max);
/// Limite configurée (même si désactivée), ou -1.
int CSNativeLimitGet(void);
bool CSNativeLimitEnabled(void);
bool CSNativeLimitSet(int percent);
bool CSNativeLimitSetEnabled(bool enabled);

#endif
