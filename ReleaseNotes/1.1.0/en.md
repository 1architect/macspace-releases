## MacSpace 1.1.0

Hi! I'm Gio, MacSpace creator.

I was not expecting MacSpace to be so well received by the community, so thank you so much for your support!

As we move forward with the project, today we introduce an important new feature: app cache cleaning.

Currently there are numerous paid, free and open source solutions for cache cleaning.

MacSpace takes a new approach on the matter: instead of individual app guided development, the default MacSpace backend uses an app agnostic solution based on the main available frameworks for app development on MacOS.

And instead of cleaning everything up just for the sake of big numbers, MacSpace suggests to erase only the things that will actually not come back to eat your disk just after cleanup. But of course if you want you can delete everything, just make sure to check all apps you'd like to reset.

And because there are lots of great solutions on the market, you can also choose to use them instead of MacSpace default solution. When cleaning MacSpace will point you to open your favorite app. Or to use none at all too. Just remember to select the preferred one in settings.

We are also deprecating two debloat toggles that MacOS does not recognize anymore and were causing issues with the mail app.

For dessert, lots of bug fixes and refinements! See you soon.

- **App cache cleaning.** MacSpace frees the caches that will not come straight back, for any app. Check the others if you want to reset them too. Free quits the open apps first, and an app can ask you to save.
- **Choose who frees the caches** in Settings: MacSpace, or another cleaner you have installed.
- **More to free.** Developer caches, Homebrew, the Trash, the system log, old app copies, crash-report symbols, and Time Machine snapshots and old backups.
- **Open a chart block** to see what it is made of, and show a row's files in the Finder.
- **3× faster System Data scan.**
- **One look for freeing space,** ending with an All done page.
- **A window that remembers its size and place,** with Minimize and Maximize on the dashboard.
- **Removed two Debloat switches** that macOS no longer recognizes and that broke Mail search: Generative search indexing and Apple Intelligence features.
- **Many fixes and refinements.**
