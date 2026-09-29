# Upstream files patched in this fork

One line per upstream file changed, with the ticket and the reason.

- apps/api/plane/bgtasks/issue_activities_task.py: PLN-3, publish an ids-only live event from a finally block after each activity.
- apps/api/plane/app/views/issue/base.py: PLN-3, publish after bulk delete (ids captured first) and after bulk date update.
- apps/api/plane/app/views/issue/archive.py: PLN-3, publish after bulk archive.
