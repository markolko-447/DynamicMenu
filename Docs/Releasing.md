# Releasing a new version

DynamicMenu updates itself with [Sparkle](https://sparkle-project.org). The app reads
`https://markolko-447.github.io/DynamicMenu/appcast.xml`, which is `website/appcast.xml` in
this repository. Each release adds one entry to that file.

## One-time setup

1. Add Sparkle to the project in Xcode with File, Add Package Dependencies, using
   `https://github.com/sparkle-project/Sparkle` and adding the **Sparkle** product to the
   DynamicMenu target.
2. Generate the signing key with Sparkle's `generate_keys` tool. It keeps the private key in
   your login Keychain and prints the public key.
3. Put the public key in `Config/Updates.plist` as `SUPublicEDKey`. The feed address is in the
   same file, and Xcode merges both into the app's Info.plist.
4. Export the private key with `generate_keys -x sparkle-private-key` and keep that file in a
   password manager. Never commit it. Losing it means every installed copy has to be
   reinstalled by hand once.

## For every release

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The build number must go up every
   time, or Sparkle will not offer the update.
2. Build the app in the Release configuration and zip it.

   ```sh
   ditto -c -k --keepParent DynamicMenu.app DynamicMenu-1.1.zip
   ```

3. Sign the zip. This prints the `sparkle:edSignature` and `length` values.

   ```sh
   sign_update DynamicMenu-1.1.zip
   ```

4. Publish the zip as a GitHub release.

   ```sh
   gh release create v1.1 DynamicMenu-1.1.zip --title "DynamicMenu 1.1" --notes "What changed."
   ```

5. Add an entry to the top of `website/appcast.xml`, inside `<channel>`, then commit and push.
   GitHub Pages publishes the new feed a minute later.

   ```xml
   <item>
     <title>Version 1.1</title>
     <sparkle:version>2</sparkle:version>
     <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
     <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
     <pubDate>Wed, 19 Nov 2026 12:00:00 +0000</pubDate>
     <description><![CDATA[<ul><li>What changed.</li></ul>]]></description>
     <enclosure
       url="https://github.com/markolko-447/DynamicMenu/releases/download/v1.1/DynamicMenu-1.1.zip"
       sparkle:edSignature="SIGNATURE FROM STEP 3"
       length="LENGTH FROM STEP 3"
       type="application/octet-stream"/>
   </item>
   ```

Version 1.0 does not contain Sparkle, so people who have it install the first version with
updates once by hand. After that, updates arrive on their own.
