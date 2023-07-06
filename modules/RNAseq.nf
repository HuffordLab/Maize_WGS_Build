#! /usr/bin/env nextflow
nextflow.enable.dsl=2

process SamToFastq {
  tag "${bam.fileName}"
  label 'gatk'
  publishDir "${params.outdir}/01_MarkAdapters/"

  input:  // reads.bam
  path(bam)

  output: // reads_interleaved.fq
  tuple val("${bam.simpleName}"), path("${bam.simpleName}_newR1.fq"), path("${bam.simpleName}_newR2.fq")

  script:
  """
  #! /usr/bin/env bash
  $gatk_app --java-options "${java_options}" SamToFastq \
    --INPUT $bam \
    --FASTQ ${bam.simpleName}_newR1.fq \
    --SECOND_END_FASTQ ${bam.simpleName}_newR2.fq \
    --VALIDATION_STRINGENCY SILENT \
    --USE_JDK_DEFLATER true \
    --USE_JDK_INFLATER true
  """

  stub:
  """
  #! /usr/bin/env bash
  touch ${bam.simpleName}_newR1.fq
  touch ${bam.simpleName}_newR2.fq
  """
}

process STAR_index {
  tag "${genome_fasta.simpleName}"
  label 'star'
  publishDir "${params.outdir}/02_MapReads"
  input: tuple path(genome_fasta), path(gtf)

  output: // [genome.fasta, [genome_index files]]
  tuple path("$genome_fasta"), path("Genome/STAR_index")

  script:
  """
  #! /usr/bin/env bash
  $star_app \
  --runThreadN $task.cpus \
  --runMode genomeGenerate \
  --genomeDir Genome/STAR_index \
  --genomeFastaFiles $genome_fasta \
  --sjdbGTFfile $gtf \
  $star_index_params
  """
}

process STAR_align {
  tag "${readname}"
  label 'star'
  publishDir "${params.outdir}/02_MapReads"
  input:
  tuple path(genome_fasta), path(genome_index), val(readname), path(readpairs)

  output:
  tuple val("$readname"), path("star_twopass_output/${readname}_*.bam"), path("star_twopass_output/${readname}_*final.out") // bam? bai?

  script:
  """
  #! /usr/bin/env bash
  mkdir star_twopass_output
  $star_app \
  --runThreadN $task.cpus \
  --outFileNamePrefix star_twopass_output/${readname}_ \
  --genomeDir ${genome_index} \
  --readFilesIn $readpairs \
  --outSAMtype BAM SortedByCoordinate \
  --twopassMode Basic

  # Another option
  # https://gatk.broadinstitute.org/hc/en-us/community/posts/15104189520283-STAR-and-GATK-RNAseq-based-SNP-detection
  """
}