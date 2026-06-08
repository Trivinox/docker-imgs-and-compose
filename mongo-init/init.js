// Creates the application user with read/write access on meandb.
// Executed once by MongoDB when the container is first created.
db.createUser({
  user: 'appuser',
  pwd:  'apppassword',
  roles: [{ role: 'readWrite', db: 'meandb' }]
});
