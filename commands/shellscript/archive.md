# ditto
```zsh
ditto -c -k --sequesterRsrc --keepParent "$folder" "$folder.zip"
```

- -k = zip
- -c = create archive
- --keepParent = keep folder inside zip
- --sequesterRsrc = handles macOSs metadata

