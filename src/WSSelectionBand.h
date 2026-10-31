/*
 * WSSelectionBand.h — the rubber band both of Workspace's icon surfaces draw.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **TWO VIEWS OWN THIS GESTURE AND MUST DRAW IT THE SAME WAY.** The desktop (`WSDesktopView`) and a file window's icon
 * view (`WSIconView`) each begin a band on a press in the empty space between icons — they hit-test and select with their
 * own models — but the band is one appearance and lives here rather than in two `drawRect:` methods that would drift.
 *
 * The appearance is the design owner's: a SEMITRANSPARENT accent wash inside a SOLID hairline of a darker shade of that
 * same accent. The darker shade is derived (`-shadowWithLevel:`, a move toward black) rather than written down, so the
 * border follows the accent if the accent ever moves.
 */
#ifndef WORKSPACE_WSSELECTIONBAND_H
#define WORKSPACE_WSSELECTIONBAND_H

#import <Foundation/NSGeometry.h>

/* How much of the accent shows through the wash. A band is a pointer's footprint over icons, not a plate: it has to say
 * "these are being taken" without hiding what is under it. */
#define WSSelectionBandFillAlpha 0.30
/* How far the border moves toward black from the accent — dark enough to read as an edge on a white icon view, and
 * against a wallpaper. */
#define WSSelectionBandShadowLevel 0.45
/* A band narrower than this in either direction is a CLICK, not a gesture, and drawing one would flicker a hairline on
 * every press in the empty space. */
#define WSSelectionBandMinimumExtent 2.0

/* **THE BAND ITSELF: the wash, then the hairline.** Drawn in the receiver's own coordinates — both callers pass a rect
 * they have already normalised — and clipped to nothing, because a band over the view's edge is a band the person is
 * still dragging.
 *
 * THE HAIRLINE IS INSET BY HALF A POINT so a one-point stroke lands on whole pixels instead of straddling two, which is
 * what makes it look drawn rather than smeared. */
void WSSelectionBandDraw(NSRect band);

#endif /* WORKSPACE_WSSELECTIONBAND_H */
