# Hosted migration baseline provenance

These 44 original upstream migrations are immutable reference copies, not active migrations.
The fork was installed into a new, empty hosted project using the server-assigned
versions recorded in manifest.json: 22 individual migrations followed by the exact
tested remaining-schema baseline. Active files in ../../migrations match that history.

Only two adaptations were made: automatic permanent message and agent housekeeping
purge schedules were omitted. The functions remain for explicit use. See the manifest
for original/applied SHA-256 checksums, mapping, differences, and the successful
disposable batch-validation CI run.

Do not restore these files into the active migration directory or push the original
44-migration history to the hosted project. Future changes must be new migrations;
never edit an applied file. Never apply supabase/seed.sql to hosted production.
The seed remains exclusively for disposable local development and CI.
