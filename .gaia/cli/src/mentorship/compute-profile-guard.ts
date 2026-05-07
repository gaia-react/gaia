import type {StorageRoots} from '../storage/paths.js';
import {isMentorshipEnabled} from './config.js';

/**
 * Compute-profile short-circuit predicate.
 *
 * `gaia telemetry compute-profile` calls this at entry and exits 0 silently
 * if it returns true. When mentorship is disabled, `compute-profile` does
 * no work and `profile.md` is not regenerated.
 *
 * `enabled === null` (pre-decision) and `enabled === false` (opted out)
 * both short-circuit. Only `enabled === true` lets compute-profile proceed.
 */
export const shouldShortCircuitComputeProfile = (
  roots: StorageRoots
): boolean => !isMentorshipEnabled(roots);
