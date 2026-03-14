import semver from 'semver';

const normalize = (version) => {
  if (!version) {
    return null;
  }
  return semver.valid(version) || semver.valid(semver.coerce(version));
};

export const isVersionGreater = (candidate, current) => {
  const candidateNormalized = normalize(candidate);
  const currentNormalized = normalize(current);

  if (!candidateNormalized || !currentNormalized) {
    return false;
  }

  return semver.gt(candidateNormalized, currentNormalized);
};

export const isVersionEqual = (left, right) => {
  const leftNormalized = normalize(left);
  const rightNormalized = normalize(right);

  if (!leftNormalized || !rightNormalized) {
    return left === right;
  }

  return semver.eq(leftNormalized, rightNormalized);
};
